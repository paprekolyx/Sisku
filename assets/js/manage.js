/* ==========================================================================
   SISKU · manage.js — подраздел «Справочники» вкладки «Управление»
   (v0.9.0-draft; переименован с «Оплата и доставка» в v0.16.0 — решение
   владельца 06.10.2026: сюда же добавляются справочники других выпадающих
   списков; первый — причины возврата, fp №3).
   Список и редактирование delivery_methods / payment_methods / return_reasons /
   writeoff_reasons (v0.20.0, fp №9 — причины списаний; ответ владельца 7.2
   от 10.10.2026: справочник здесь, посев без «Уценки», системные причины
   не деактивируются) / badges (v0.21.0, fp №16 — бейджи карточки товара;
   состав утверждён владельцем 05.10.2026, системный «New» не деактивируется,
   удаление — только деактивацией):
   название, код, цены (вилка), активность. История заказов не страдает:
   способы отключаются (is_active), а удаление (с v0.14.0 — настоящие
   DELETE-политики скрипта 16, фикс F09) блокирует FK, если способ уже
   использован в заказах.
   v0.22.1 (грабля №6): стартовая загрузка — ОДИН RPC draft_manage_bundle
   (скрипт 36) вместо 5 параллельных select'ов; поведение не изменилось.
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    deliveries: [], payments: [], reasons: [], writeoffs: [], badges: [],
    kind: 'delivery',          /* какой справочник правим в модалке: delivery | payment | reason | writeoff | badge */
    editingId: null, saving: false
  };
  /* v0.16.0 (fp №3): причины возврата — третий справочник страницы;
     удаление — только деактивацией (DELETE-политики нет: причина может
     быть использована в заявках, скрипт 22)
     v0.20.0 (fp №9, ответ 7.2): причины списаний — четвёртый справочник;
     удаление — только деактивацией; системные (is_system) не деактивируются
     v0.21.0 (fp №16): бейджи — пятый справочник; удаление — только
     деактивацией (назначения могут существовать); системный «New» —
     не деактивируется и не редактируется (значок в списке) */
  function kindMeta(kind) {
    if (kind === 'reason')   return { list: state.reasons,   table: 'return_reasons' };
    if (kind === 'writeoff') return { list: state.writeoffs, table: 'writeoff_reasons' };
    if (kind === 'badge')    return { list: state.badges,    table: 'badges' };
    if (kind === 'payment')  return { list: state.payments,  table: 'payment_methods' };
    return { list: state.deliveries, table: 'delivery_methods' };
  }

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc, money = SiskuUtil.money;

  function load() {
    $('mng-error').hidden = true;
    if (!db) {
      $('mng-error').hidden = false;
      $('mng-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    /* v0.22.1 (грабля №6): пять справочников — ОДИН RPC draft_manage_bundle
       (скрипт 36) вместо пяти прямых select'ов; ключи бандла — имена
       таблиц. Допустимость «скрипт 22/31/33 ещё не выполнен» ушла в
       историю — таблицы в baseline ревизии 2. Волна v0.23.0:
       «Уведомления» — отдельная страница (Д2 v0230); бандл остаётся
       в составе 5 ключей. */
    db.rpc('draft_manage_bundle').then(function (r) {
      if (r.error) throw r.error;
      var d = r.data || {};
      state.deliveries = d.deliveries || [];
      state.payments = d.payments || [];
      state.reasons = d.return_reasons || [];
      state.writeoffs = d.writeoff_reasons || [];
      state.badges = d.badges || [];
      render();
    }).catch(function (e) {
      $('mng-error').hidden = false;
      $('mng-error').textContent = 'Ошибка загрузки: ' + e.message;
    });
  }

  function render() {
    $('del-body').innerHTML = state.deliveries.map(function (m) {
      return '<tr>' +
        '<td class="user-fio" data-edit="' + m.id + '" data-kind="delivery" title="Открыть редактирование">' + esc(m.name) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(m.code) + '</td>' +
        '<td class="tabular">' + (m.base_price > 0 ? money(m.base_price) : 'бесплатно') + '</td>' +
        '<td class="tabular muted">' + (m.price_max ? money(m.price_max) : '—') + '</td>' +
        '<td><button class="btn" data-toggle="' + m.id + '" data-kind="delivery" style="min-height:32px;padding:0 12px">' +
          (m.is_active ? 'активен' : 'отключён') + '</button></td>' +
        '<td><button class="btn" data-del="' + m.id + '" data-kind="delivery" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
    $('pay-body').innerHTML = state.payments.map(function (m) {
      return '<tr>' +
        '<td class="user-fio" data-edit="' + m.id + '" data-kind="payment" title="Открыть редактирование">' + esc(m.name) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(m.code) + '</td>' +
        '<td><button class="btn" data-toggle="' + m.id + '" data-kind="payment" style="min-height:32px;padding:0 12px">' +
          (m.is_active ? 'активен' : 'отключён') + '</button></td>' +
        '<td><button class="btn" data-del="' + m.id + '" data-kind="payment" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
    /* v0.16.0: причины возврата — без кнопки «Удалить» (деактивация вместо
       удаления: причина может быть использована в заявках) */
    $('rrn-body').innerHTML = state.reasons.map(function (m) {
      return '<tr>' +
        '<td class="user-fio" data-edit="' + m.id + '" data-kind="reason" title="Открыть редактирование">' + esc(m.name) + '</td>' +
        '<td class="tabular muted">' + m.sort_order + '</td>' +
        '<td><button class="btn" data-toggle="' + m.id + '" data-kind="reason" style="min-height:32px;padding:0 12px">' +
          (m.is_active ? 'активна' : 'отключена') + '</button></td>' +
        '<td></td>' +
      '</tr>';
    }).join('') || '<tr><td colspan="4" class="muted">Причин пока нет — добавьте первую (форма заявки на возврат витрины берёт список отсюда).</td></tr>';
    /* v0.20.0 (fp №9, ответ 7.2): причины списаний — системные не правятся
       и не деактивируются (подставляются проведением инвентаризации, Д6) */
    $('wrn-body').innerHTML = state.writeoffs.map(function (m) {
      return '<tr>' +
        '<td class="user-fio"' + (m.is_system ? '' : ' data-edit="' + m.id + '" data-kind="writeoff" title="Открыть редактирование"') + '>' +
          esc(m.name) + (m.is_system ? ' <span class="inv-sys-mark" title="Системная причина: подставляется проведением инвентаризации, не деактивируется">системная</span>' : '') + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(m.code) + '</td>' +
        '<td class="tabular muted">' + m.sort_order + '</td>' +
        '<td><button class="btn" data-toggle="' + m.id + '" data-kind="writeoff" style="min-height:32px;padding:0 12px"' +
          (m.is_system ? ' disabled title="Системная причина — не деактивируется"' : '') + '>' +
          (m.is_active ? 'активна' : 'отключена') + '</button></td>' +
        '<td></td>' +
      '</tr>';
    }).join('') || '<tr><td colspan="5" class="muted">Причин пока нет — посев скрипта 31: Брак, Витринный образец, Недостача, Излишек, Прочее (без «Уценки» — ответ 7.2).</td></tr>';
    /* v0.21.0 (fp №16): бейджи — системный «New» не правится и не
       деактивируется (назначается всем товарам по умолчанию, ответ 1.9);
       удаление — только деактивацией (назначения могут существовать) */
    $('bdg-body').innerHTML = state.badges.map(function (m) {
      return '<tr>' +
        '<td class="user-fio"' + (m.is_system ? '' : ' data-edit="' + m.id + '" data-kind="badge" title="Открыть редактирование"') + '>' +
          esc(m.name) + (m.is_system ? ' <span class="inv-sys-mark" title="Системный бейдж: по умолчанию у всех товаров, не деактивируется; снятие с товара — вручную (ответ 7.4)">системный</span>' : '') + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(m.code) + '</td>' +
        '<td class="tabular muted">' + m.sort_order + '</td>' +
        '<td><button class="btn" data-toggle="' + m.id + '" data-kind="badge" style="min-height:32px;padding:0 12px"' +
          (m.is_system ? ' disabled title="Системный бейдж — не деактивируется"' : '') + '>' +
          (m.is_active ? 'активен' : 'отключён') + '</button></td>' +
        '<td></td>' +
      '</tr>';
    }).join('') || '<tr><td colspan="5" class="muted">Бейджей пока нет — посев скрипта 33: New (системный), Хит, Заканчивается, Скоро, % (состав утверждён владельцем 05.10.2026).</td></tr>';
  }

  function openModal(kind, id) {
    state.kind = kind;
    state.editingId = id || null;
    state.saving = false;
    $('mm-submit').disabled = false;
    var m = id ? kindMeta(kind).list.filter(function (x) { return x.id === id; })[0] : null;
    if (kind === 'reason') {
      /* v0.16.0: причина возврата — название + порядок + активность (без кода и цен) */
      $('mm-title').textContent = m ? 'Правка причины: ' + m.name : 'Новая причина возврата';
      $('mm-name').value = m ? m.name : '';
      $('mm-code').value = '';
      $('mm-sort').value = m ? m.sort_order : (state.reasons.length + 1);
      $('mm-active').checked = m ? m.is_active : true;
      $('mm-active-label').textContent = 'Причина активна (видна в форме заявки на возврат)';
    } else if (kind === 'writeoff') {
      /* v0.20.0 (fp №9): причина списания — название + код (только при создании)
         + порядок + активность; системные причины в модалку не попадают */
      $('mm-title').textContent = m ? 'Правка причины: ' + m.name : 'Новая причина списания';
      $('mm-name').value = m ? m.name : '';
      $('mm-code').value = m ? m.code : '';
      $('mm-code').disabled = !!m;           /* код не меняем задним числом */
      $('mm-sort').value = m ? m.sort_order : (state.writeoffs.length + 1);
      $('mm-active').checked = m ? m.is_active : true;
      $('mm-active-label').textContent = 'Причина активна (видна в формах списаний)';
    } else if (kind === 'badge') {
      /* v0.21.0 (fp №16): бейдж — название + код (только при создании)
         + порядок + активность; системные бейджи в модалку не попадают
         (в списке без data-edit). Название «%» — легально (1 символ):
         минимальная длина для бейджей — 1 */
      $('mm-title').textContent = m ? 'Правка бейджа: ' + m.name : 'Новый бейдж';
      $('mm-name').value = m ? m.name : '';
      $('mm-code').value = m ? m.code : '';
      $('mm-code').disabled = !!m;           /* код не меняем задним числом */
      $('mm-sort').value = m ? m.sort_order : (state.badges.length + 1);
      $('mm-active').checked = m ? m.is_active : true;
      $('mm-active-label').textContent = 'Бейдж активен (виден на карточках витрины, предлагается для назначения)';
    } else {
      $('mm-title').textContent = (m ? 'Правка: ' : 'Новый способ ') + (kind === 'delivery' ? 'доставки' : 'оплаты') + (m ? m.name : '');
      $('mm-name').value = m ? m.name : '';
      $('mm-code').value = m ? m.code : '';
      $('mm-code').disabled = !!m;           /* код не меняем задним числом */
      $('mm-base').value = m && kind === 'delivery' ? (m.base_price || '') : '';
      $('mm-max').value = m && kind === 'delivery' && m.price_max ? m.price_max : '';
      $('mm-active').checked = m ? m.is_active : true;
      $('mm-active-label').textContent = 'Способ активен (виден в форме заказа)';
    }
    $('mm-code-field').hidden = kind === 'reason';
    $('mm-prices').hidden = kind !== 'delivery';
    $('mm-sort-field').hidden = kind !== 'reason' && kind !== 'writeoff' && kind !== 'badge';
    ['mm-name-err', 'mm-code-err', 'mm-error'].forEach(function (x) { $(x).hidden = true; });
    $('mng-modal-backdrop').classList.add('open');
    if (window.enhanceNumbers) enhanceNumbers(document.getElementById('mng-form'));
  }
  function closeModal() { $('mng-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    if (state.saving) return;
    var errBox = $('mm-error');
    errBox.hidden = true;
    var name = $('mm-name').value.trim();
    var code = state.kind === 'reason' ? '' : $('mm-code').value.trim().toLowerCase();
    var ok = true;
    $('mm-name-err').hidden = true; $('mm-code-err').hidden = true;
    /* v0.21.0: название бейджа — от 1 символа (посевной «%» — легален) */
    if (name.length < (state.kind === 'badge' ? 1 : 3)) { $('mm-name-err').textContent = 'Укажите название'; $('mm-name-err').hidden = false; ok = false; }
    if (state.kind !== 'reason' && !state.editingId && !/^[a-z0-9_-]{2,30}$/.test(code)) {
      $('mm-code-err').textContent = 'Код: латиница/цифры/дефис, 2–30 символов'; $('mm-code-err').hidden = false; ok = false;
    }
    if (!ok) return;
    state.saving = true;
    $('mm-submit').disabled = true;
    var table = kindMeta(state.kind).table;
    var row = { name: name, is_active: $('mm-active').checked };
    if (state.kind === 'delivery') {
      row.base_price = Number($('mm-base').value || 0);
      row.price_max = $('mm-max').value ? Number($('mm-max').value) : null;
      if (row.price_max != null && row.price_max < row.base_price) row.price_max = row.base_price;
    }
    if (state.kind === 'reason' || state.kind === 'writeoff' || state.kind === 'badge') {
      row.sort_order = Math.max(1, Number($('mm-sort').value || 1));
    }
    if (state.kind !== 'reason' && !state.editingId) row.code = code;
    var q = state.editingId
      ? db.from(table).update(row).eq('id', state.editingId)
      : db.from(table).insert(row);
    q.then(function (res) {
      state.saving = false;
      $('mm-submit').disabled = false;
      if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
      closeModal();
      load();
    }).catch(function (err) {
      state.saving = false;
      $('mm-submit').disabled = false;
      errBox.textContent = 'Ошибка сети: ' + err.message;
      errBox.hidden = false;
    });
  }

  /* v0.22.0 (П23): панель-заглушка «Журнал действий» перенесена в
     «Пользователи» (users.html#audit) — hash-логика manage.html убрана */

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('btn-new-delivery').addEventListener('click', function () { openModal('delivery', null); });
    $('btn-new-payment').addEventListener('click', function () { openModal('payment', null); });
    $('btn-new-reason').addEventListener('click', function () { openModal('reason', null); });   /* v0.16.0 */
    $('btn-new-writeoff').addEventListener('click', function () { openModal('writeoff', null); });   /* v0.20.0 (fp №9) */
    $('btn-new-badge').addEventListener('click', function () { openModal('badge', null); });          /* v0.21.0 (fp №16) */
    $('mng-modal-close').addEventListener('click', closeModal);
    $('mng-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('mng-modal-backdrop')) closeModal(); });
    $('mng-form').addEventListener('submit', save);

    document.querySelectorAll('tbody').forEach(function (tbody) {
      tbody.addEventListener('click', function (e) {
        var tg = e.target.closest('button[data-toggle]');
        if (tg) {
          var kind = tg.getAttribute('data-kind');
          var id = Number(tg.getAttribute('data-toggle'));
          var meta = kindMeta(kind);
          var m = meta.list.filter(function (x) { return x.id === id; })[0];
          if (!m) return;
          /* v0.20.0 (Д6): системные причины списаний не деактивируются
             (кнопка disabled; guard — вторая страховка от гонки)
             v0.21.0 (fp №16): системный бейдж «New» — тем же порядком */
          if (kind === 'writeoff' && m.is_system) {
            alert('Системная причина («' + m.name + '») не деактивируется: её подставляет проведение инвентаризации.');
            return;
          }
          if (kind === 'badge' && m.is_system) {
            alert('Системный бейдж («' + m.name + '») не деактивируется: он назначается всем товарам по умолчанию (снятие с товара — вручную в карточке).');
            return;
          }
          tg.disabled = true;
          var table = meta.table;
          db.from(table).update({ is_active: !m.is_active }).eq('id', id).then(function (res) {
            if (res.error) { alert('Не удалось переключить: ' + res.error.message); tg.disabled = false; return; }
            load();
          });
          return;
        }
        var del = e.target.closest('button[data-del]');
        if (del) {
          var kindD = del.getAttribute('data-kind');
          var idD = Number(del.getAttribute('data-del'));
          var metaD = kindMeta(kindD);
          var mD = metaD.list.filter(function (x) { return x.id === idD; })[0];
          var tableD = metaD.table;
          if (!confirm('Удалить способ «' + (mD ? mD.name : '') + '»? Способ, который уже используется в заказах, база удалить не даст.')) return;
          del.disabled = true;
          /* фикс F09 (v0.14.0): DELETE-политики добавлены скриптом 16 —
             удаление настоящее. .select() возвращает удалённые строки:
             пустой массив = строка не удалена (редкая гонка), FK (23503) =
             способ использован в заказах → предлагаем отключить */
          db.from(tableD).delete().eq('id', idD).select('id').then(function (res) {
            if (res.error) {
              alert(res.error.code === '23503'
                ? 'Способ «' + (mD ? mD.name : '') + '» используется в заказах — удалить нельзя. Отключите его кнопкой активности.'
                : 'Не удалось удалить: ' + res.error.message);
              del.disabled = false;
              return;
            }
            if (!res.data || !res.data.length) {
              alert('Способ не удалён: строка уже отсутствует в базе. Список обновлён.');
            }
            load();
          }).catch(function (err) { alert('Ошибка сети: ' + err.message); del.disabled = false; });
          return;
        }
        var ed = e.target.closest('[data-edit]');
        if (ed) openModal(ed.getAttribute('data-kind'), Number(ed.getAttribute('data-edit')));
      });
    });

    if (window.enhanceNumbers) enhanceNumbers(document.getElementById('mng-form'));
    load();
  });
})();
