/* ==========================================================================
   SISKU · users.js — страница «Пользователи» (v0.4.0-draft)
   Черновая ролевая модель: admin (администратор), assembler (сборщик),
   manager (менеджер), partner (бизнес-партнёр). Страницы ролями пока
   не ограничиваются — модель копится для боевой версии.
   Пароль хранится хешем SHA-256 (только для макета!).
   v0.15.0 (правка 2.19, скрипт 21): колонка «Телефон» (admin_users.phone,
   кликабельный tel:), валидация мессенджера при вводе — только https-ссылка
   whitelisted-сервиса или tel: (обычный текст «нет» больше не превращается
   в битую ссылку); пусто — «нет». safeUrl остаётся вторым рубежом.
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

  /* правка 2.19: whitelist доменов мессенджеров (https) — обычный текст
     в поле ссылки не принимается; телефон — отдельная колонка (скрипт 21) */
  var MESS_DOMAINS = ['t.me', 'telegram.me', 'wa.me', 'whatsapp.com',
                      'vk.me', 'vk.com', 'max.ru', 'ok.ru'];
  function messengerOk(v) {
    if (!v) return true;                       /* пусто — «нет», допустимо */
    if (/^tel:/i.test(v)) return SiskuUtil.phoneOk(v.replace(/^tel:/i, ''));
    var u = null;
    try { u = new URL(v); } catch (e) { return false; }
    if (u.protocol !== 'https:') return false;
    var host = u.hostname.toLowerCase().replace(/^www\./, '');
    return MESS_DOMAINS.indexOf(host) !== -1;
  }

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc, emailOk = SiskuUtil.emailOk;
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
          '<td class="user-fio" data-edit="' + u.id + '" title="Открыть редактирование">' + esc(u.fio) +
            (u.is_active ? '' : ' <span class="muted">(отключён)</span>') + '</td>' +
          /* правка 2.5 (v0.16.0, записка 8): mailto — только для валидного
             e-mail (тот же паттерн, что tel:); старые данные («-» и мусор) —
             обычный текст без ссылки */
          '<td class="muted">' + (emailOk(u.email)
            ? '<a class="mail-link" href="mailto:' + esc(u.email) + '">' + esc(u.email) + '</a>'
            : esc(u.email)) + '</td>' +
          '<td>' + (function () {
            /* фикс F05 (v0.14.0): whitelist схем — javascript: в messenger_url больше не исполняется;
               правка 2.19 (v0.15.0): пусто — «нет» (владелец просила не показывать «—») */
            var mu = SiskuUtil.safeUrl(u.messenger_url);
            return mu ? '<a href="' + esc(mu) + '" target="_blank" rel="noopener">ссылка</a>' : '<span class="muted">нет</span>';
          })() + '</td>' +
          '<td>' + (u.phone
            ? '<a class="tel-link" href="tel:' + esc(String(u.phone).replace(/[^\d+]/g, '')) + '">' + esc(u.phone) + '</a>'
            : '<span class="muted">нет</span>') + '</td>' +
          '<td><span class="role-pill" data-role="' + esc(u.role) + '">' + esc(ROLES[u.role] || u.role) + '</span></td>' +
          '<td class="tabular muted">' + new Date(u.created_at).toLocaleDateString('ru-RU') + '</td>' +
          '<td><button class="btn" data-del="' + u.id + '" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
        '</tr>';
      }).join('');
    });
  }

  /* ---------- модалка ---------- */
  function openModal(userId) {
    state.editingId = userId || null;
    state.saving = false;
    var submitBtn = $('um-submit');
    if (submitBtn) submitBtn.disabled = false;
    var u = userId ? state.users.filter(function (x) { return x.id === userId; })[0] : null;
    $('um-title').textContent = u ? 'Редактирование: ' + u.fio : 'Новый администратор';
    $('um-fio').value = u ? u.fio : '';
    $('um-email').value = u ? u.email : '';
    $('um-mess').value = u ? (u.messenger_url || '') : '';
    $('um-phone').value = u ? (u.phone || '') : '';
    $('um-role').value = u ? u.role : 'manager';
    $('um-pass').value = '';
    $('um-pass-hint').hidden = !u;
    ['um-fio-err', 'um-email-err', 'um-phone-err', 'um-mess-err', 'um-pass-err', 'um-error'].forEach(function (id) { $(id).hidden = true; });
    $('user-modal-backdrop').classList.add('open');
    if (window.enhanceSelects) enhanceSelects($('user-modal-backdrop'));
  }
  function closeModal() { $('user-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    if (state.saving) return;                 /* защита от повторных кликов «Сохранить» */
    var errBox = $('um-error');
    errBox.hidden = true;
    var fio = $('um-fio').value.trim();
    var email = $('um-email').value.trim();
    var mess = $('um-mess').value.trim();
    var phone = $('um-phone').value.trim();
    var role = $('um-role').value;
    var pass = $('um-pass').value;
    var ok = true;
    $('um-fio-err').hidden = true; $('um-email-err').hidden = true;
    $('um-phone-err').hidden = true; $('um-mess-err').hidden = true; $('um-pass-err').hidden = true;
    if (fio.length < 5) { $('um-fio-err').textContent = 'Укажите ФИО полностью'; $('um-fio-err').hidden = false; ok = false; }
    if (!emailOk(email)) { $('um-email-err').textContent = 'Формат почты: name@example.ru'; $('um-email-err').hidden = false; ok = false; }
    /* правка 2.19 (v0.15.0): телефон — формат РФ; мессенджер — только ссылка */
    if (phone && !SiskuUtil.phoneOk(phone)) {
      $('um-phone-err').textContent = 'Формат телефона: +7 (999) 123-45-67 или 8 999 123-45-67';
      $('um-phone-err').hidden = false; ok = false;
    }
    if (!messengerOk(mess)) {
      $('um-mess-err').textContent = 'Мессенджер: ссылка https:// (t.me, wa.me, vk.me, max.ru, ok.ru, whatsapp.com, telegram.me, vk.com) или tel:+79991234567. Обычный текст не принимается — оставьте поле пустым.';
      $('um-mess-err').hidden = false; ok = false;
    }
    if (!state.editingId && pass.length < 6) { $('um-pass-err').textContent = 'Пароль минимум 6 символов'; $('um-pass-err').hidden = false; ok = false; }
    if (state.editingId && pass && pass.length < 6) { $('um-pass-err').textContent = 'Пароль минимум 6 символов'; $('um-pass-err').hidden = false; ok = false; }
    if (!ok) return;

    var finish = function (hash) {
      state.saving = true;
      var btn = $('um-submit');
      btn.disabled = true;
      var row = { fio: fio, email: email, messenger_url: mess || null, phone: phone || null, role: role, updated_at: new Date().toISOString() };
      if (hash) row.password_hash = hash;
      var q = state.editingId
        ? db.from('admin_users').update(row).eq('id', state.editingId)
        : db.from('admin_users').insert(Object.assign({ password_hash: hash, is_active: true }, row));
      q.then(function (res) {
        state.saving = false;
        btn.disabled = false;
        if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
        closeModal();
        load();
      }).catch(function (e) {
        state.saving = false;
        btn.disabled = false;
        errBox.textContent = 'Ошибка сети: ' + e.message;
        errBox.hidden = false;
      });
    };
    if (pass) sha256hex(pass).then(finish);
    else finish(null);
  }

  /* правка 2.11 (v0.15.0): users.html#roles — панель-заглушка «Ролевая модель» */
  function applyRolesHash() {
    var on = location.hash === '#roles';
    $('panel-roles').hidden = !on;
    $('panel-users').hidden = on;
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    applyRolesHash();
    window.addEventListener('hashchange', applyRolesHash);
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('btn-new').addEventListener('click', function () { openModal(null); });
    $('user-modal-close').addEventListener('click', closeModal);
    $('user-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('user-modal-backdrop')) closeModal(); });
    $('user-form').addEventListener('submit', save);
    $('users-body').addEventListener('click', function (e) {
      /* удаление администратора */
      var del = e.target.closest('button[data-del]');
      if (del) {
        var id = Number(del.getAttribute('data-del'));
        var u = state.users.filter(function (x) { return x.id === id; })[0];
        if (!confirm('Удалить администратора ' + (u ? u.fio : '№ ' + id) + '? Действие необратимо.')) return;
        del.disabled = true;
        db.from('admin_users').delete().eq('id', id).then(function (res) {
          if (res.error) { alert('Не удалось удалить: ' + res.error.message); del.disabled = false; return; }
          load();
        }).catch(function (err) { alert('Ошибка сети: ' + err.message); del.disabled = false; });
        return;
      }
      /* редактирование — клик по ФИО */
      var ed = e.target.closest('[data-edit]');
      if (ed) openModal(Number(ed.getAttribute('data-edit')));
    });
    load();
  });
})();
