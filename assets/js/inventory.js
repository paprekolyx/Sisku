/* ==========================================================================
   SISKU · inventory.js — панель «Магазин → Инвентаризация» (v0.20.0, fp №9)
   Решение Д14 (10.10.2026): отдельный модуль (products.js ~32 КБ не
   раздувается; панель самостоятельная). Подключается в products.html после
   products.js; страница — #panel-inventory (products.js переключает панели
   по hash #inventory, этот модуль — наполняет).

   Состав (решения Д2–Д7, Д12; ответы владельца 7.1–7.3 от 10.10.2026):
   • «Планирование» — сессии (пилюли статусов planned/in_progress/done/
     cancelled), модалка создания (область всё/категории + мультивыбор
     категорий, план-дата, участники — мультивыбор админов); действия:
     «Начать», «Открыть лист», «Отменить» (модалка подтверждения; из done —
     недоступно), «Итоги»; переходы статусов — только ручные, параллельные
     идущие сессии — штатно (7.3(а));
   • «Лист» — snapshot (в системе / в резерве / в карантине / ожидаемо
     физически), ввод факта, расхождение на лету со знаками «+» (излишек) /
     «−» (недостача) и подсветкой (Д4); «Сохранить факт» — batch одним RPC
     (грабля №6); «Завершить» — модалка ПРЕДУПРЕЖДЕНИЯ (Д5, АН-21 вариант (б):
     перечень расхождений + ожидаемые новые остатки + текст про ноль/минус
     и резервы) → «Провести»;
   • «Журнал списаний» — фильтры (причина/сессия/поиск), пагинация 30,
     «Ручное списание» (модалка: вариант-поиск, qty ±, причина, комментарий;
     guard свободных единиц — на сервере), CSV; движения карантина сюда не
     попадают (единый журнал склада — fp №3b, v0.29.0, ответ 7.13).
   Данные: draft_inventory_bundle (план/лист) и draft_writeoffs_bundle
   (журнал) — по одному RPC на представление; запись — только RPC скрипта 32.
   Авторство операций — текст 'draft-admin' (настоящая авторизация — M2).
   ========================================================================== */
(function () {
  'use strict';

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32) */
  var esc = SiskuUtil.esc, fmtDt = SiskuUtil.fmtDateTime, fmtD = SiskuUtil.fmtDate,
      dayKey = SiskuUtil.dayKey, csvCell = SiskuUtil.csvCell,
      friendly = SiskuUtil.friendlyDbError;

  var INV_STATUS = {
    planned: 'Запланирована', in_progress: 'Идёт',
    done: 'Завершена', cancelled: 'Отменена'
  };
  var PAGE = 30;   /* пагинация журнала — паттерн очередей админки */

  var state = {
    inited: false,
    sessions: [], reasons: [], categories: [], admins: [],
    journal: [], jReason: '', jSession: '', jSearch: '', jPage: 1,
    sheetSession: null,     /* объект сессии открытого листа */
    sheet: [],              /* строки листа (draft_inventory_bundle(id).sheet) */
    saving: false,
    variants: null,         /* варианты для модалки ручного списания (лениво) */
    woPicked: null,         /* выбранный вариант {vid, name, article, label, stock} */
    cancelTarget: null,     /* id сессии, которую отменяем */
    finishing: false
  };

  function statusPill(code) {
    return '<span class="status-pill" data-code="inv_' + code + '">' +
      esc(INV_STATUS[code] || code) + '</span>';
  }
  function signed(n) {
    if (n == null) return '<span class="muted">—</span>';
    if (n === 0) return '<span class="muted">0</span>';
    return n > 0
      ? '<span class="wo-pos" title="Излишек">+' + n + '</span>'
      : '<span class="wo-neg" title="Недостача">−' + Math.abs(n) + '</span>';
  }
  function sessionById(id) {
    return state.sessions.filter(function (s) { return s.id === id; })[0] || null;
  }
  function showError(id, e) {
    var box = $(id);
    box.textContent = friendly(e) || (e && e.message) || String(e);
    box.hidden = false;
  }

  /* ---------- загрузка (Д9: один RPC на представление; лениво при открытии) ---------- */
  function loadAll() {
    if (!db) {
      $('inv-loading').hidden = true;
      showError('inv-error', { message: dbError || 'База не подключена: заполните assets/js/config.js' });
      return;
    }
    $('inv-loading').hidden = false;
    $('inv-error').hidden = true;
    Promise.all([
      db.rpc('draft_inventory_bundle'),
      db.rpc('draft_writeoffs_bundle')
    ]).then(function (res) {
      res.forEach(function (r) { if (r.error) throw r.error; });
      var inv = res[0].data || {};
      var wo = res[1].data || {};
      state.sessions = inv.sessions || [];
      state.reasons = inv.reasons || [];
      state.categories = inv.categories || [];
      state.admins = inv.admins || [];
      state.journal = wo.writeoffs || [];
      $('inv-loading').hidden = true;
      renderSessions();
      buildJournalFilters();
      renderJournal();
      if (state.sheetSession) openSheet(state.sheetSession.id, true);   /* лист открыт — освежить */
    }).catch(function (e) {
      $('inv-loading').hidden = true;
      showError('inv-error', e);
    });
  }

  /* ---------- секция «Планирование» ---------- */
  function scopeLabel(s) {
    if (s.scope === 'all') return 'Весь магазин';
    var names = s.scope_names || [];
    return 'Категории: ' + (names.length ? esc(names.join(', ')) : '—');
  }
  function renderSessions() {
    var body = $('inv-sessions-body');
    $('inv-sessions-empty').hidden = state.sessions.length !== 0;
    body.innerHTML = state.sessions.map(function (s) {
      var acts = '';
      if (s.status === 'planned') {
        acts += '<button class="btn" data-act="start" data-id="' + s.id + '" style="min-height:32px;padding:0 12px">Начать</button> ';
        acts += '<button class="btn" data-act="cancel" data-id="' + s.id + '" style="min-height:32px;padding:0 12px">Отменить</button>';
      } else if (s.status === 'in_progress') {
        acts += '<button class="btn" data-act="sheet" data-id="' + s.id + '" style="min-height:32px;padding:0 12px">Открыть лист</button> ';
        acts += '<button class="btn" data-act="cancel" data-id="' + s.id + '" style="min-height:32px;padding:0 12px">Отменить</button>';
      } else {
        acts += '<button class="btn" data-act="sheet" data-id="' + s.id + '" style="min-height:32px;padding:0 12px">' +
          (s.status === 'done' ? 'Итоги' : 'Лист') + '</button>';
      }
      var names = (s.participant_names || []).join(', ');
      return '<tr>' +
        '<td class="tabular"><b>№ ' + s.id + '</b></td>' +
        '<td style="font-size:13px">' + scopeLabel(s) + '</td>' +
        '<td class="tabular muted">' + (s.plan_date ? fmtD(s.plan_date + 'T00:00:00') : '—') + '</td>' +
        '<td>' + statusPill(s.status) +
          (s.discrepancies > 0 ? ' <span class="inv-disc" title="Расхождений в листе">± ' + s.discrepancies + '</span>' : '') + '</td>' +
        '<td class="tabular">' + s.items_counted + ' / ' + s.items_total + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(names || '—') + '</td>' +
        '<td class="tabular muted">' + fmtDt(s.created_at) + '</td>' +
        '<td style="white-space:nowrap">' + acts + '</td>' +
      '</tr>';
    }).join('');
  }

  function startSession(id) {
    if (!db) return;
    db.rpc('admin_start_inventory_session', { p_session_id: id, p_changed_by: 'draft-admin' })
      .then(function (res) {
        if (res.error) { alert('Не удалось начать: ' + friendly(res.error)); return; }
        loadAll();
      }).catch(function (e) { alert('Ошибка сети: ' + e.message); });
  }

  /* ---------- отмена сессии (Д2) ---------- */
  function openCancelModal(id) {
    var s = sessionById(id);
    if (!s) return;
    state.cancelTarget = id;
    var counted = s.items_counted > 0 ? ' Введённые факты (' + s.items_counted + ') сохранятся как история; списания проводиться не будут.' : '';
    $('inv-cancel-text').textContent = 'Сессия № ' + id + ' (' + (INV_STATUS[s.status] || s.status) + '). После отмены статус не вернуть — можно создать новую сессию.' + counted;
    $('inv-cancel-error').hidden = true;
    $('inv-cancel-submit').disabled = false;
    $('inv-cancel-backdrop').classList.add('open');
  }
  function doCancel() {
    var id = state.cancelTarget;
    if (!id || !db) return;
    $('inv-cancel-submit').disabled = true;
    db.rpc('admin_cancel_inventory_session', { p_session_id: id, p_changed_by: 'draft-admin' })
      .then(function (res) {
        $('inv-cancel-submit').disabled = false;
        if (res.error) { showError('inv-cancel-error', res.error); return; }
        $('inv-cancel-backdrop').classList.remove('open');
        if (state.sheetSession && state.sheetSession.id === id) closeSheet();
        loadAll();
      }).catch(function (e) {
        $('inv-cancel-submit').disabled = false;
        showError('inv-cancel-error', { message: 'Ошибка сети: ' + e.message });
      });
  }

  /* ---------- секция «Лист» (Д4) ---------- */
  function openSheet(id, silent) {
    if (!db) return;
    if (!silent) {
      $('inv-sheet-section').hidden = false;
      $('inv-sheet-loading').hidden = false;
      $('inv-sheet-error').hidden = true;
    } else {
      $('inv-sheet-loading').hidden = false;
    }
    db.rpc('draft_inventory_bundle', { p_session_id: id }).then(function (res) {
      $('inv-sheet-loading').hidden = true;
      if (res.error) { showError('inv-sheet-error', res.error); return; }
      var d = res.data || {};
      state.sheet = d.sheet || [];
      state.sheetSession = sessionById(id) || { id: id, status: 'planned' };
      renderSheet();
      if (!silent) $('inv-sheet-section').scrollIntoView({ behavior: 'smooth', block: 'start' });
    }).catch(function (e) {
      $('inv-sheet-loading').hidden = true;
      showError('inv-sheet-error', { message: 'Ошибка сети: ' + e.message });
    });
  }
  function closeSheet() {
    state.sheetSession = null;
    state.sheet = [];
    $('inv-sheet-section').hidden = true;
  }
  function renderSheet() {
    var s = state.sheetSession;
    if (!s) return;
    var editable = s.status === 'in_progress';
    $('inv-sheet-title').textContent = (s.status === 'done' ? 'Итоги сессии' : 'Лист инвентаризации') +
      ' — № ' + s.id + ' · ' + (INV_STATUS[s.status] || s.status);
    $('inv-save-facts').hidden = !editable;
    $('inv-finish').hidden = !editable;
    $('inv-sheet-empty').hidden = state.sheet.length !== 0;
    $('inv-sheet-body').innerHTML = state.sheet.map(function (r) {
      var fact = r.fact_qty == null ? '' : r.fact_qty;
      var diff = r.fact_qty == null ? null : r.diff;
      var rowCls = diff == null || diff === 0 ? '' : (diff > 0 ? ' class="inv-row-pos"' : ' class="inv-row-neg"');
      return '<tr data-row="' + r.item_id + '"' + rowCls + '>' +
        '<td>' + esc(r.product) + '<div class="muted" style="font-size:12px">' + esc(r.article) + '</div></td>' +
        '<td>' + esc(r.variant) + '</td>' +
        '<td class="tabular">' + r.system_qty + '</td>' +
        '<td class="tabular' + (r.reserved_qty > 0 ? ' inv-reserved' : '') + '">' + r.reserved_qty + '</td>' +
        '<td class="tabular' + (r.quarantine_qty > 0 ? ' quarantine-cell' : '') + '">' + r.quarantine_qty + '</td>' +
        '<td class="tabular"><b>' + r.expected_qty + '</b></td>' +
        '<td class="tabular">' + (editable
          ? '<input type="number" class="inv-fact" data-item="' + r.item_id + '" data-expected="' + r.expected_qty +
            '" data-orig="' + fact + '" min="0" max="99999" step="1" value="' + fact + '" data-no-stepper aria-label="Факт: ' + esc(r.product) + ' ' + esc(r.variant) + '">'
          : (r.fact_qty == null ? '<span class="muted">—</span>' : '<b>' + r.fact_qty + '</b>')) + '</td>' +
        '<td class="tabular inv-diff">' + signed(diff) + '</td>' +
      '</tr>';
    }).join('');
    if (editable) {
      $('inv-sheet-hint').textContent = 'Ожидаемо физически = остаток в системе + резерв + карантин (snapshot на момент старта сессии; продажи во время сессии лист не меняют). Расхождение = факт − ожидаемо: «+» излишек, «−» недостача. Сохраняйте факт перед завершением.';
    } else if (s.status === 'done') {
      $('inv-sheet-hint').textContent = 'Сессия завершена: расхождения проведены в журнал списаний (строки «Инвентаризация № ' + s.id + '»), остатки изменены. Лист — только для просмотра.';
    } else if (s.status === 'cancelled') {
      $('inv-sheet-hint').textContent = 'Сессия отменена: введённые факты сохранены как история, списания не проводились. Лист — только для просмотра.';
    } else {
      $('inv-sheet-hint').textContent = 'Сессия ещё не начата — лист будет доступен для ввода после кнопки «Начать».';
    }
  }

  /* пересчёт расхождения на лету (делегирование input) */
  function onSheetInput(e) {
    var inp = e.target.closest('input.inv-fact');
    if (!inp) return;
    var td = inp.closest('tr').querySelector('.inv-diff');
    var tr = inp.closest('tr');
    var expected = Number(inp.getAttribute('data-expected'));
    if (inp.value === '') {
      td.innerHTML = signed(null);
      tr.className = '';
      return;
    }
    var fact = Number(inp.value);
    if (!isFinite(fact)) return;
    var d = fact - expected;
    td.innerHTML = signed(d);
    tr.className = d === 0 ? '' : (d > 0 ? 'inv-row-pos' : 'inv-row-neg');
  }

  function collectFacts() {
    var items = [], bad = null;
    $('inv-sheet-body').querySelectorAll('input.inv-fact').forEach(function (inp) {
      if (inp.value === '') return;
      var v = Number(inp.value);
      if (!isFinite(v) || v < 0 || v > 99999 || Math.round(v) !== v) {
        bad = bad || ('позиция № ' + inp.getAttribute('data-item') + ': целое число 0–99999');
        return;
      }
      if (inp.value !== inp.getAttribute('data-orig')) {
        items.push({ item_id: Number(inp.getAttribute('data-item')), fact_qty: Math.round(v) });
      }
    });
    return { items: items, bad: bad };
  }

  function saveFacts(btn) {
    var s = state.sheetSession;
    if (!s || !db || state.saving) return;
    var c = collectFacts();
    if (c.bad) { alert('Проверьте ввод: ' + c.bad); return; }
    if (!c.items.length) { alert('Нет изменений: введите факт хотя бы по одной позиции.'); return; }
    state.saving = true;
    btn.disabled = true;
    db.rpc('admin_save_inventory_items', {
      p: { session_id: s.id, changed_by: 'draft-admin', items: c.items }
    }).then(function (res) {
      state.saving = false;
      btn.disabled = false;
      if (res.error) { alert('Не удалось сохранить: ' + friendly(res.error)); return; }
      openSheet(s.id, true);   /* лист и заголовок — из свежего бандла */
      db.rpc('draft_inventory_bundle').then(function (r2) {   /* агрегаты «посчитано» в плане */
        if (!r2.error && r2.data) {
          state.sessions = r2.data.sessions || state.sessions;
          state.sheetSession = (r2.data.sessions || []).filter(function (x) { return x.id === s.id; })[0] || state.sheetSession;
          renderSessions();
          renderSheet();
        }
      });
    }).catch(function (e) {
      state.saving = false;
      btn.disabled = false;
      alert('Ошибка сети: ' + e.message);
    });
  }

  /* ---------- завершение: модалка предупреждения (Д5, АН-21 вариант (б)) ---------- */
  function openFinishModal() {
    var s = state.sheetSession;
    if (!s || s.status !== 'in_progress') return;
    var c = collectFacts();
    if (c.bad) { alert('Проверьте ввод: ' + c.bad); return; }
    if (c.items.length) {
      alert('Есть несохранённые изменения факта — сначала «Сохранить факт», затем «Завершить».');
      return;
    }
    var rows = state.sheet.filter(function (r) { return r.fact_qty != null && r.diff !== 0; });
    $('inv-f-title').textContent = 'Завершение инвентаризации № ' + s.id;
    $('inv-f-list').innerHTML =
      '<thead><tr><th>Позиция</th><th style="text-align:right">Ожидаемо</th><th style="text-align:right">Факт</th>' +
      '<th style="text-align:right">Расхождение</th><th style="text-align:right">Новый остаток</th></tr></thead><tbody>' +
      (rows.length
        ? rows.map(function (r) {
            var ns = r.stock_now + r.diff;
            return '<tr' + (ns <= 0 ? ' class="inv-row-neg"' : '') + '>' +
              '<td>' + esc(r.product) + ' · ' + esc(r.variant) + '</td>' +
              '<td class="tabular" style="text-align:right">' + r.expected_qty + '</td>' +
              '<td class="tabular" style="text-align:right">' + r.fact_qty + '</td>' +
              '<td class="tabular" style="text-align:right">' + signed(r.diff) + '</td>' +
              '<td class="tabular" style="text-align:right"><b>' + ns + '</b>' +
                (ns < 0 ? ' <span class="wo-neg" title="Уход в минус">минус</span>' : (ns === 0 ? ' <span class="muted">ноль</span>' : '')) + '</td>' +
            '</tr>';
          }).join('')
        : '<tr><td colspan="5" class="muted">Расхождений нет — сессия завершится нулевой (списания не создаются).</td></tr>') +
      '</tbody>';
    $('inv-f-error').hidden = true;
    $('inv-f-submit').disabled = false;
    $('inv-finish-backdrop').classList.add('open');
  }
  function doFinish() {
    var s = state.sheetSession;
    if (!s || !db || state.finishing) return;
    state.finishing = true;
    $('inv-f-submit').disabled = true;
    db.rpc('admin_finish_inventory_session', { p_session_id: s.id, p_changed_by: 'draft-admin' })
      .then(function (res) {
        state.finishing = false;
        $('inv-f-submit').disabled = false;
        if (res.error) { showError('inv-f-error', res.error); return; }
        $('inv-finish-backdrop').classList.remove('open');
        var d = res.data || {};
        var neg = d.negative_positions || [];
        alert('Инвентаризация № ' + s.id + ' проведена.\n' +
          'Строк журнала: ' + (d.writeoffs_created || 0) +
          ' (списано ' + (d.shortages || 0) + ' шт., излишки ' + (d.surpluses || 0) + ' шт).' +
          (neg.length
            ? '\n' + 'Позиции с нулевым/минусовым остатком (' + neg.length + '): ' +
              neg.map(function (p) { return p.product + ' ' + p.variant + ' → ' + p.stock; }).join('; ') +
              '.\n' + 'Проверьте страницу «Сборка» и сообщите владельцу.'
            : ''));
        loadAll();   /* лист открыт — loadAll освежит его сам (read-only, статус done) */
      }).catch(function (e) {
        state.finishing = false;
        $('inv-f-submit').disabled = false;
        showError('inv-f-error', { message: 'Ошибка сети: ' + e.message });
      });
  }

  /* ---------- журнал списаний (Д7) ---------- */
  function buildJournalFilters() {
    var keepR = $('inv-j-reason').value, keepS = $('inv-j-session').value;
    $('inv-j-reason').innerHTML = '<option value="">Все причины</option>' +
      state.reasons.map(function (r) {
        return '<option value="' + r.id + '">' + esc(r.name) + '</option>';
      }).join('');
    $('inv-j-session').innerHTML = '<option value="">Все записи</option><option value="manual">Ручные (вне сессий)</option>' +
      state.sessions.filter(function (s) { return s.status === 'done'; }).map(function (s) {
        return '<option value="' + s.id + '">Инвентаризация № ' + s.id + '</option>';
      }).join('');
    $('inv-j-reason').value = keepR;
    $('inv-j-session').value = keepS;
    state.jReason = $('inv-j-reason').value;
    state.jSession = $('inv-j-session').value;
    $('inv-j-reason').dispatchEvent(new Event('refresh'));
    $('inv-j-session').dispatchEvent(new Event('refresh'));
    if (window.enhanceSelects) enhanceSelects();
  }
  function filteredJournal() {
    var q = state.jSearch.trim().toLowerCase();
    return state.journal.filter(function (w) {
      if (state.jReason && String(w.reason_id) !== state.jReason) return false;
      if (state.jSession === 'manual' && w.session_id != null) return false;
      if (state.jSession && state.jSession !== 'manual' && String(w.session_id) !== state.jSession) return false;
      if (q) {
        var hay = ((w.product || '') + ' ' + (w.article || '') + ' ' + (w.variant || '')).toLowerCase();
        if (hay.indexOf(q) === -1) return false;
      }
      return true;
    });
  }
  function renderJournal() {
    var list = filteredJournal();
    var pages = Math.max(1, Math.ceil(list.length / PAGE));
    if (state.jPage > pages) state.jPage = pages;
    if (state.jPage < 1) state.jPage = 1;
    var visible = list.slice((state.jPage - 1) * PAGE, state.jPage * PAGE);
    $('inv-j-empty').hidden = list.length !== 0;
    $('inv-j-empty').textContent = state.journal.length
      ? 'Ничего не найдено по фильтру — выберите другую причину/сессию или очистите поиск.'
      : 'Списаний пока нет. Записи появляются при проведении инвентаризаций и через кнопку «Ручное списание».';
    $('inv-j-body').innerHTML = visible.map(function (w) {
      var cm = w.comment ? (w.comment.length > 60 ? w.comment.slice(0, 60) + '…' : w.comment) : '—';
      return '<tr>' +
        '<td class="tabular muted">' + fmtDt(w.created_at) + '</td>' +
        '<td>' + esc(w.product) + '<div class="muted" style="font-size:12px">' + esc(w.article) + '</div></td>' +
        '<td>' + esc(w.variant) + '</td>' +
        '<td class="tabular"><b>' + signed(w.qty) + '</b></td>' +
        '<td>' + esc(w.reason) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(w.changed_by) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(cm) + '</td>' +
        '<td>' + (w.session_id
          ? '<button class="btn" data-act="jsheet" data-id="' + w.session_id + '" style="min-height:28px;padding:0 10px" title="Открыть итоги сессии">№ ' + w.session_id + '</button>'
          : '<span class="muted">вручную</span>') + '</td>' +
      '</tr>';
    }).join('');
    $('inv-j-pager').hidden = pages <= 1;
    $('inv-j-info').textContent = 'Стр. ' + state.jPage + ' из ' + pages + ' · записей: ' + list.length;
  }
  function exportJournalCsv() {
    var list = filteredJournal();
    var R = [];
    R.push(['Журнал списаний и излишков — выгрузка ' + fmtD(new Date())]);
    R.push(['Дата', 'Артикул', 'Товар', 'Вариант', 'Кол-во', 'Причина', 'Автор', 'Комментарий', 'Сессия']);
    list.forEach(function (w) {
      R.push([fmtDt(w.created_at), w.article, w.product, w.variant, w.qty, w.reason,
        w.changed_by, (w.comment || '').replace(/;/g, ',').replace(/\n/g, ' '),
        w.session_id ? '№ ' + w.session_id : 'ручное']);
    });
    var csv = R.map(function (row) { return row.map(csvCell).join(';'); }).join('\r\n');
    var blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sisku-writeoffs-' + dayKey(new Date()) + '.csv';   /* локальная дата (фикс F29) */
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* ---------- модалка создания сессии (Д3/Д12) ---------- */
  function openCreateModal() {
    $('inv-c-error').hidden = true;
    $('inv-c-submit').disabled = false;
    $('inv-c-date').value = '';
    $('inv-c-cats').innerHTML = state.categories.map(function (c) {
      return '<label class="inv-check"><input type="checkbox" value="' + c.id + '"> ' + esc(c.name) + '</label>';
    }).join('') || '<span class="muted" style="font-size:13px">Категорий нет</span>';
    $('inv-c-participants').innerHTML = state.admins.map(function (a) {
      return '<label class="inv-check"><input type="checkbox" value="' + a.id + '"> ' + esc(a.fio) +
        ' <span class="muted" style="font-size:12px">(' + esc(a.role) + ')</span></label>';
    }).join('') || '<span class="muted" style="font-size:13px">Администраторов нет — создайте на странице «Пользователи»</span>';
    syncScope();
    $('inv-create-backdrop').classList.add('open');
    if (window.enhanceDates) enhanceDates($('inv-create-form'));
  }
  function syncScope() {
    $('inv-c-cats-field').hidden = $('inv-c-scope').value !== 'categories';
  }
  function createSession(e) {
    e.preventDefault();
    if (!db) return;
    var scope = $('inv-c-scope').value;
    var cats = [];
    if (scope === 'categories') {
      $('inv-c-cats').querySelectorAll('input:checked').forEach(function (cb) { cats.push(Number(cb.value)); });
      if (!cats.length) { showError('inv-c-error', { message: 'Выберите хотя бы одну категорию' }); return; }
    }
    var parts = [];
    $('inv-c-participants').querySelectorAll('input:checked').forEach(function (cb) { parts.push(Number(cb.value)); });
    var plan = $('inv-c-date').value || null;
    $('inv-c-submit').disabled = true;
    $('inv-c-error').hidden = true;
    db.rpc('admin_create_inventory_session', {
      p: { scope: scope, category_ids: cats, participant_ids: parts, plan_date: plan, created_by: 'draft-admin' }
    }).then(function (res) {
      $('inv-c-submit').disabled = false;
      if (res.error) { showError('inv-c-error', res.error); return; }
      $('inv-create-backdrop').classList.remove('open');
      loadAll();
    }).catch(function (err) {
      $('inv-c-submit').disabled = false;
      showError('inv-c-error', { message: 'Ошибка сети: ' + err.message });
    });
  }

  /* ---------- ручное списание (Д7) ---------- */
  function openWoModal() {
    state.woPicked = null;
    $('inv-w-picked').textContent = 'Вариант не выбран';
    $('inv-w-search').value = '';
    $('inv-w-qty').value = '';
    $('inv-w-comment').value = '';
    $('inv-w-error').hidden = true;
    $('inv-w-submit').disabled = false;
    $('inv-w-reason').innerHTML = '<option value="">— выберите —</option>' +
      state.reasons.filter(function (r) { return r.is_active; }).map(function (r) {
        return '<option value="' + r.id + '">' + esc(r.name) + (r.is_system ? ' (системная)' : '') + '</option>';
      }).join('');
    $('inv-w-reason').dispatchEvent(new Event('refresh'));
    if (window.enhanceSelects) enhanceSelects();
    $('inv-wo-backdrop').classList.add('open');
    if (state.variants) { renderWoList(); return; }
    $('inv-w-list').innerHTML = '<span class="muted" style="font-size:13px">Загружаем варианты…</span>';
    Promise.all([
      db.from('products').select('id,article,name,is_active').order('article'),
      db.from('product_variants').select('id,label,stock,product_id').order('sort_order')
    ]).then(function (res) {
      res.forEach(function (r) { if (r.error) throw r.error; });
      var prods = {};
      (res[0].data || []).forEach(function (p) { prods[p.id] = p; });
      state.variants = (res[1].data || []).map(function (v) {
        var p = prods[v.product_id] || {};
        return { vid: v.id, label: v.label, stock: v.stock, name: p.name || '?', article: p.article || '?', active: !!p.is_active };
      }).filter(function (v) { return v.active; });
      renderWoList();
    }).catch(function (e) {
      $('inv-w-list').innerHTML = '';
      showError('inv-w-error', e);
    });
  }
  function renderWoList() {
    var q = $('inv-w-search').value.trim().toLowerCase();
    var list = (state.variants || []).filter(function (v) {
      if (!q) return true;
      return ((v.name + ' ' + v.article + ' ' + v.label).toLowerCase().indexOf(q) !== -1);
    }).slice(0, 50);
    $('inv-w-list').innerHTML = list.map(function (v) {
      return '<button type="button" class="inv-pick' + (state.woPicked && state.woPicked.vid === v.vid ? ' picked' : '') +
        '" data-vid="' + v.vid + '">' + esc(v.article) + ' · ' + esc(v.name) + ' — ' + esc(v.label) +
        ' <span class="muted" style="font-size:12px">(свободно: ' + v.stock + ')</span></button>';
    }).join('') || '<span class="muted" style="font-size:13px">Ничего не найдено</span>';
  }
  function pickVariant(vid) {
    state.woPicked = (state.variants || []).filter(function (v) { return v.vid === vid; })[0] || null;
    $('inv-w-picked').textContent = state.woPicked
      ? 'Выбрано: ' + state.woPicked.article + ' · ' + state.woPicked.name + ' — ' + state.woPicked.label +
        ' (свободно: ' + state.woPicked.stock + ' шт.)'
      : 'Вариант не выбран';
    renderWoList();
  }
  function createWriteoff(e) {
    e.preventDefault();
    if (!db) return;
    $('inv-w-error').hidden = true;
    if (!state.woPicked) { showError('inv-w-error', { message: 'Выберите вариант товара' }); return; }
    var q = $('inv-w-qty').value.trim();
    if (q === '' || !/^-?\d{1,5}$/.test(q) || Number(q) === 0) {
      showError('inv-w-error', { message: 'Количество: целое число, не ноль («−» списание / «+» излишек)' }); return;
    }
    var reason = $('inv-w-reason').value;
    if (!reason) { showError('inv-w-error', { message: 'Выберите причину' }); return; }
    $('inv-w-submit').disabled = true;
    db.rpc('admin_create_writeoff', {
      p: {
        variant_id: state.woPicked.vid, qty: Number(q), reason_id: Number(reason),
        comment: $('inv-w-comment').value.trim() || null, changed_by: 'draft-admin'
      }
    }).then(function (res) {
      $('inv-w-submit').disabled = false;
      if (res.error) { showError('inv-w-error', res.error); return; }
      $('inv-wo-backdrop').classList.remove('open');
      state.variants = null;   /* остатки изменились — при следующем открытии перезагрузим */
      loadAll();
      if (state.sheetSession) openSheet(state.sheetSession.id, true);
    }).catch(function (err) {
      $('inv-w-submit').disabled = false;
      showError('inv-w-error', { message: 'Ошибка сети: ' + err.message });
    });
  }

  /* ---------- инициализация и делегирование ---------- */
  function init() {
    if (state.inited) return;
    state.inited = true;

    $('inv-refresh').addEventListener('click', loadAll);
    $('inv-new').addEventListener('click', openCreateModal);

    /* сессии: делегирование действий */
    $('inv-sessions-body').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-act]');
      if (!b) return;
      var id = Number(b.getAttribute('data-id'));
      var act = b.getAttribute('data-act');
      if (act === 'start') { b.disabled = true; startSession(id); }
      else if (act === 'sheet') openSheet(id);
      else if (act === 'cancel') openCancelModal(id);
    });

    /* модалка создания */
    $('inv-create-close').addEventListener('click', function () { $('inv-create-backdrop').classList.remove('open'); });
    $('inv-create-backdrop').addEventListener('click', function (e) { if (e.target === $('inv-create-backdrop')) $('inv-create-backdrop').classList.remove('open'); });
    $('inv-c-scope').addEventListener('change', syncScope);
    $('inv-create-form').addEventListener('submit', createSession);

    /* лист */
    $('inv-sheet-close').addEventListener('click', closeSheet);
    $('inv-sheet-body').addEventListener('input', onSheetInput);
    $('inv-save-facts').addEventListener('click', function () { saveFacts(this); });
    $('inv-finish').addEventListener('click', openFinishModal);

    /* модалка завершения */
    $('inv-finish-close').addEventListener('click', function () { $('inv-finish-backdrop').classList.remove('open'); });
    $('inv-finish-backdrop').addEventListener('click', function (e) { if (e.target === $('inv-finish-backdrop')) $('inv-finish-backdrop').classList.remove('open'); });
    $('inv-f-submit').addEventListener('click', doFinish);

    /* модалка отмены */
    $('inv-cancel-close').addEventListener('click', function () { $('inv-cancel-backdrop').classList.remove('open'); });
    $('inv-cancel-back').addEventListener('click', function () { $('inv-cancel-backdrop').classList.remove('open'); });
    $('inv-cancel-backdrop').addEventListener('click', function (e) { if (e.target === $('inv-cancel-backdrop')) $('inv-cancel-backdrop').classList.remove('open'); });
    $('inv-cancel-submit').addEventListener('click', doCancel);

    /* журнал */
    $('inv-j-reason').addEventListener('change', function () { state.jReason = this.value; state.jPage = 1; renderJournal(); });
    $('inv-j-session').addEventListener('change', function () { state.jSession = this.value; state.jPage = 1; renderJournal(); });
    $('inv-j-search').addEventListener('input', function () { state.jSearch = this.value; state.jPage = 1; renderJournal(); });
    $('inv-j-prev').addEventListener('click', function () { state.jPage -= 1; renderJournal(); });
    $('inv-j-next').addEventListener('click', function () { state.jPage += 1; renderJournal(); });
    $('inv-j-csv').addEventListener('click', exportJournalCsv);
    $('inv-j-manual').addEventListener('click', openWoModal);
    $('inv-j-body').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-act="jsheet"]');
      if (b) openSheet(Number(b.getAttribute('data-id')));
    });

    /* модалка ручного списания */
    $('inv-wo-close').addEventListener('click', function () { $('inv-wo-backdrop').classList.remove('open'); });
    $('inv-wo-backdrop').addEventListener('click', function (e) { if (e.target === $('inv-wo-backdrop')) $('inv-wo-backdrop').classList.remove('open'); });
    $('inv-w-search').addEventListener('input', renderWoList);
    $('inv-w-list').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-vid]');
      if (b) pickVariant(Number(b.getAttribute('data-vid')));
    });
    $('inv-wo-form').addEventListener('submit', createWriteoff);

    if (window.enhanceSelects) enhanceSelects($('panel-inventory'));
    if (window.enhanceSelects) enhanceSelects($('inv-create-form'));
    if (window.enhanceSelects) enhanceSelects($('inv-wo-form'));
    if (window.enhanceDates) enhanceDates($('inv-create-form'));
    if (window.enhanceNumbers) enhanceNumbers($('inv-wo-form'));
  }

  function onHash() {
    if (location.hash !== '#inventory') return;
    init();
    loadAll();   /* при каждом открытии панели — свежие остатки и сессии */
  }

  document.addEventListener('DOMContentLoaded', function () {
    onHash();
    window.addEventListener('hashchange', onHash);
  });
})();
