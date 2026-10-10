-- ============================================================================
--  SISKU (черновик) — СКРИПТ 32: инвентаризация и списания — RPC и бандлы
-- ============================================================================
--  Волна v0.20.0 (10.10.2026) — «Инвентаризация и списания» (fp №9; решения
--  аналитика Д2/Д4–Д10 от 10.10.2026; ответы владельца 7.1–7.3, опросник
--  ред. 1.6). Состав (8 функций; create_order НЕ меняется — v9):
--    (1) admin_create_inventory_session — создание сессии 'planned'
--        + заполнение листа snapshot'ом (одна insert…select);
--    (2) admin_start_inventory_session — 'planned' → 'in_progress'
--        + ПЕРЕСЧЁТ snapshot (остатки могли измениться между планированием
--        и стартом); без guard «одна идущая» — параллельные сессии разрешены
--        (ответ 7.3(а));
--    (3) admin_cancel_inventory_session — Д2: 'planned'/'in_progress' →
--        'cancelled' (из 'done' — ошибка); факты листа сохраняются (история),
--        списания НЕ проводятся;
--    (4) admin_save_inventory_items — batch-сохранение фактов одной
--        транзакцией (upsert diff/counted_by; сессия должна идти);
--    (5) admin_finish_inventory_session — Д5/Д6, ВАРИАНТ (б) «предупреждение
--        с проведением»: по каждому ненулевому расхождению — строка writeoffs
--        (qty = diff: «−» списание / «+» излишек; причины shortage/surplus;
--        комментарий «Инвентаризация № X») + stock += diff БЕЗ guard на минус
--        (предупреждение — модалка фронтенда до вызова); блокировка вариантов
--        FOR UPDATE в детерминированном порядке variant_id (паттерн F23 —
--        без deadlock); сводка проведения — в ответе (в т.ч. negative_positions
--        — позиции с уходом в ноль/минус, для протокола); роль — только
--        «администратор» (7.3(б); фактическое ролевое ограничение — с M2,
--        в макете — мок-гейт, changed_by текстовый);
--    (6) admin_create_writeoff — Д7: ручное списание/излишек вне сессии
--        (guard stock + qty >= 0 для списаний СОХРАНЁН — резерв не
--        затрагивается: списание только из свободных единиц; минус — только
--        через проведение инвентаризации);
--    (7) draft_inventory_bundle(p_session_id) — Д9: без id — сессии
--        (с агрегатами листа) + справочник причин + категории + админы
--        (форма создания); с id — + лист (snapshot + факты + расхождения);
--    (8) draft_writeoffs_bundle — журнал списаний (с товаром/вариантом/ценой
--        для сумм «по текущей цене» — Д8, в бою — исторические цены fp №28)
--        + причины + проведённые сессии с итогами (подвкладка «Статистика →
--        Списания»; лениво — паттерн draft_returns_bundle).
--  Репликация семантики: расхождение считается от snapshot СТАРТА сессии
--  («ожидаемо на момент старта»); продажи во время идущей сессии меняют stock —
--  на лист это не влияет (документировано в инструкции волны и подсказке).
--  RLS: функции SECURITY DEFINER (владелец обходит RLS — анонимных политик у
--  сессий/листа/журнала нет, скрипт 31); EXECUTE для anon — в пределах
--  задокументированной границы черновика (SECURITY.md, A2 — до M2).
--  Идемпотентен: create or replace function. Порядок: после baseline 01–05, 09,
--  инкрементов 26–30 и скрипта 31. Применим к живой базе (инкремент — F21).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: скрипт должен выполняться в проекте Sisku после скрипта 31
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.inventory_sessions') is null
       or to_regclass('public.inventory_items') is null
       or to_regclass('public.writeoffs') is null
       or to_regclass('public.writeoff_reasons') is null then
        raise exception 'Скрипт 32: таблицы инвентаризации не найдены — сначала выполните скрипт 31_inventory_schema.sql';
    end if;
    if to_regprocedure('public.create_order(jsonb)') is null then
        raise exception 'Скрипт 32: функция create_order не найдена — выбран не тот проект Supabase или не выполнен baseline 03';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. admin_create_inventory_session — создание сессии + заполнение листа
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_create_inventory_session(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_scope   text;
    v_cats    jsonb;
    v_parts   jsonb;
    v_plan    date;
    v_by      text;
    v_sid     integer;
    v_need    integer;
    v_found   integer;
    v_items   integer;
begin
    v_scope := lower(coalesce(nullif(trim(p->>'scope'), ''), 'all'));
    if v_scope not in ('all', 'categories') then
        raise exception 'Область инвентаризации: «всё» (all) или «категории» (categories)';
    end if;

    v_cats  := coalesce(p->'category_ids', '[]'::jsonb);
    v_parts := coalesce(p->'participant_ids', '[]'::jsonb);
    if jsonb_typeof(v_cats) <> 'array' or jsonb_typeof(v_parts) <> 'array' then
        raise exception 'Списки категорий и участников — массивы id';
    end if;

    /* категории: только числа; все существуют (scope='categories' — минимум одна) */
    select count(*) into v_found
      from jsonb_array_elements_text(v_cats) e
     where translate(e, '0123456789', '') <> '' or e = '';
    if v_found > 0 then
        raise exception 'Категории: ожидаются числовые id';
    end if;
    if v_scope = 'categories' then
        v_need := jsonb_array_length(v_cats);
        if v_need = 0 then
            raise exception 'Для области «по категориям» выберите хотя бы одну категорию';
        end if;
        select count(*) into v_found
          from public.categories c
         where c.id::text in (select jsonb_array_elements_text(v_cats));
        if v_found <> v_need then
            raise exception 'Некоторые категории не найдены в справочнике';
        end if;
    else
        v_cats := '[]'::jsonb;
    end if;

    /* участники: только числа; все существуют в admin_users */
    select count(*) into v_found
      from jsonb_array_elements_text(v_parts) e
     where translate(e, '0123456789', '') <> '' or e = '';
    if v_found > 0 then
        raise exception 'Участники: ожидаются числовые id администраторов';
    end if;
    v_need := jsonb_array_length(v_parts);
    if v_need > 0 then
        select count(*) into v_found
          from public.admin_users a
         where a.id::text in (select jsonb_array_elements_text(v_parts));
        if v_found <> v_need then
            raise exception 'Некоторые участники не найдены в списке администраторов';
        end if;
    end if;

    /* план-дата: необязательна; формат ГГГГ-ММ-ДД */
    if coalesce(nullif(trim(p->>'plan_date'), ''), null) is not null then
        begin
            v_plan := (p->>'plan_date')::date;
        exception when others then
            raise exception 'План-дата: формат ГГГГ-ММ-ДД';
        end;
    end if;

    v_by := left(coalesce(nullif(trim(p->>'created_by'), ''), 'admin'), 100);

    insert into public.inventory_sessions
        (scope, scope_categories, plan_date, status, participants, created_by)
    values
        (v_scope, v_cats, v_plan, 'planned', v_parts, v_by)
    returning id into v_sid;

    /* лист — одной вставкой: активные варианты области; snapshot:
       system = stock, reserved = открытые заказы (new/confirmed/packing —
       механизм draft_reserved_map v2), quarantine = quarantine_qty;
       expected = сумма (всё физически присутствует на складе) */
    insert into public.inventory_items
        (session_id, variant_id, system_qty, reserved_qty, quarantine_qty, expected_qty)
    select v_sid, v.id, v.stock, coalesce(r.qty, 0), v.quarantine_qty,
           v.stock + coalesce(r.qty, 0) + v.quarantine_qty
      from public.product_variants v
      join public.products pr on pr.id = v.product_id and pr.is_active
      left join (
            select i.variant_id, sum(i.quantity) as qty
              from public.order_items i
              join public.orders o on o.id = i.order_id
              join public.order_statuses s on s.id = o.status_id
             where s.code in ('new', 'confirmed', 'packing')
               and i.variant_id is not null
             group by i.variant_id
           ) r on r.variant_id = v.id
     where v_scope = 'all'
        or pr.category_id::text in (select jsonb_array_elements_text(v_cats));

    get diagnostics v_items = row_count;

    return jsonb_build_object(
        'ok', true,
        'session_id', v_sid,
        'items_count', v_items);
end;
$$;

comment on function public.admin_create_inventory_session is
    'Создание сессии инвентаризации (волна v0.20.0, fp №9, Д2/Д3): p = {scope: all|categories, category_ids?, plan_date?, participant_ids?, created_by?}; статус planned (переходы только ручные — авто-старта по план-дате нет); лист заполняется snapshot-ом активных вариантов области (stock + резерв открытых заказов + карантин = «ожидаемо физически») одной вставкой';

-- ----------------------------------------------------------------------------
-- 2. admin_start_inventory_session — ручной старт + пересчёт snapshot
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_start_inventory_session(
    p_session_id integer,
    p_changed_by text default 'admin')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_status text;
begin
    select status into v_status
      from public.inventory_sessions
     where id = p_session_id
     for update;
    if not found then
        raise exception 'Сессия инвентаризации № % не найдена', p_session_id;
    end if;
    if v_status = 'in_progress' then
        raise exception 'Сессия № % уже идёт', p_session_id;
    end if;
    if v_status in ('done', 'cancelled') then
        raise exception 'Нельзя начать завершённую или отменённую сессию (№ %)', p_session_id;
    end if;

    /* пересчёт snapshot: остатки могли измениться между планированием и
       стартом (продажи, карантин, ручные списания) */
    update public.inventory_items ii
       set system_qty     = v.stock,
           reserved_qty   = coalesce(r.qty, 0),
           quarantine_qty = v.quarantine_qty,
           expected_qty   = v.stock + coalesce(r.qty, 0) + v.quarantine_qty,
           diff           = case when ii.fact_qty is not null
                                 then ii.fact_qty
                                      - (v.stock + coalesce(r.qty, 0) + v.quarantine_qty)
                            end
      from public.product_variants v
      left join (
            select i.variant_id, sum(i.quantity) as qty
              from public.order_items i
              join public.orders o on o.id = i.order_id
              join public.order_statuses s on s.id = o.status_id
             where s.code in ('new', 'confirmed', 'packing')
               and i.variant_id is not null
             group by i.variant_id
           ) r on r.variant_id = v.id
     where ii.session_id = p_session_id
       and ii.variant_id = v.id;

    update public.inventory_sessions
       set status = 'in_progress', started_at = now()
     where id = p_session_id;

    /* p_changed_by — авторство перехода; журнал действий сессии не ведётся
       (заглушка «Журнал действий» — M1/M2), параметр — на будущее */
    return jsonb_build_object('ok', true);
end;
$$;

comment on function public.admin_start_inventory_session is
    'Ручной старт сессии (волна v0.20.0, Д2): planned → in_progress + ПЕРЕСЧЁТ snapshot листа (остатки могли измениться между планированием и стартом); авто-старта по план-дате нет; параллельные идущие сессии разрешены (ответ 7.3(а) — guard «одна идущая» не делается); из in_progress/done/cancelled — ошибка';

-- ----------------------------------------------------------------------------
-- 3. admin_cancel_inventory_session — отмена (Д2: из любого статуса, кроме done)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_cancel_inventory_session(
    p_session_id integer,
    p_changed_by text default 'admin')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_status text;
begin
    select status into v_status
      from public.inventory_sessions
     where id = p_session_id
     for update;
    if not found then
        raise exception 'Сессия инвентаризации № % не найдена', p_session_id;
    end if;
    if v_status = 'done' then
        raise exception 'Завершённую сессию нельзя отменить (№ %)', p_session_id;
    end if;
    if v_status = 'cancelled' then
        raise exception 'Сессия № % уже отменена', p_session_id;
    end if;

    update public.inventory_sessions
       set status = 'cancelled', finished_at = now()
     where id = p_session_id;

    /* факты листа сохраняются (история), списания НЕ проводятся */
    return jsonb_build_object('ok', true);
end;
$$;

comment on function public.admin_cancel_inventory_session is
    'Отмена сессии (волна v0.20.0, Д2): planned/in_progress → cancelled (finished_at = now()); из done — ошибка «Завершённую сессию нельзя отменить»; факты листа сохраняются как история, списания не проводятся';

-- ----------------------------------------------------------------------------
-- 4. admin_save_inventory_items — batch-сохранение фактов (Д4)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_save_inventory_items(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_sid    integer;
    v_by     text;
    v_status text;
    v_el     jsonb;
    v_item   integer;
    v_fact   integer;
    v_saved  integer := 0;
begin
    if translate(coalesce(p->>'session_id', ''), '0123456789', '') <> ''
       or coalesce(p->>'session_id', '') = '' then
        raise exception 'Не указан номер сессии';
    end if;
    v_sid := (p->>'session_id')::integer;
    v_by  := left(coalesce(nullif(trim(p->>'changed_by'), ''), 'admin'), 100);

    select status into v_status
      from public.inventory_sessions
     where id = v_sid
     for update;
    if not found then
        raise exception 'Сессия инвентаризации № % не найдена', v_sid;
    end if;
    if v_status <> 'in_progress' then
        raise exception 'Факты можно вводить только у идущей сессии (№ % — статус «%»)', v_sid, v_status;
    end if;

    if coalesce(jsonb_typeof(p->'items'), 'null') <> 'array' then
        raise exception 'Позиции листа: ожидается массив {item_id, fact_qty}';
    end if;

    for v_el in select * from jsonb_array_elements(p->'items')
    loop
        if translate(coalesce(v_el->>'item_id', ''), '0123456789', '') <> ''
           or coalesce(v_el->>'item_id', '') = '' then
            raise exception 'Позиция листа: item_id — число';
        end if;
        v_item := (v_el->>'item_id')::integer;
        if translate(coalesce(v_el->>'fact_qty', ''), '0123456789', '') <> ''
           or coalesce(v_el->>'fact_qty', '') = ''
           or length(trim(v_el->>'fact_qty')) > 5 then
            raise exception 'Факт позиции № %: целое число 0–99999', v_item;
        end if;
        v_fact := (v_el->>'fact_qty')::integer;
        if v_fact > 99999 then
            raise exception 'Факт позиции № %: целое число 0–99999', v_item;
        end if;

        update public.inventory_items
           set fact_qty   = v_fact,
               diff       = v_fact - expected_qty,
               counted_by = v_by,
               updated_at = now()
         where id = v_item
           and session_id = v_sid;
        if not found then
            raise exception 'Позиция листа № % не принадлежит сессии № %', v_item, v_sid;
        end if;
        v_saved := v_saved + 1;
    end loop;

    return jsonb_build_object('ok', true, 'saved', v_saved);
end;
$$;

comment on function public.admin_save_inventory_items is
    'Сохранение фактов листа одной транзакцией (волна v0.20.0, Д4; грабля №6 — batch, не построчные запросы): p = {session_id, changed_by?, items: [{item_id, fact_qty}…]}; сессия должна идти (in_progress); fact_qty — целое 0–99999; diff = fact − expected (от snapshot старта) пересчитывается сервером';

-- ----------------------------------------------------------------------------
-- 5. admin_finish_inventory_session — проведение (Д5/Д6, вариант (б))
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_finish_inventory_session(
    p_session_id integer,
    p_changed_by text default 'admin')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_status   text;
    v_by       text;
    v_short_id integer;
    v_surr_id  integer;
    v_rec      record;
    v_new      integer;
    v_lines    integer := 0;
    v_short    integer := 0;
    v_surr     integer := 0;
    v_neg      jsonb  := '[]'::jsonb;
begin
    select status into v_status
      from public.inventory_sessions
     where id = p_session_id
     for update;
    if not found then
        raise exception 'Сессия инвентаризации № % не найдена', p_session_id;
    end if;
    if v_status = 'done' then
        raise exception 'Сессия № % уже завершена', p_session_id;
    end if;
    if v_status = 'cancelled' then
        raise exception 'Отменённую сессию нельзя завершить (№ %)', p_session_id;
    end if;
    if v_status <> 'in_progress' then
        raise exception 'Сессию № % нужно сначала начать (статус «%»)', p_session_id, v_status;
    end if;

    v_by := left(coalesce(nullif(trim(p_changed_by), ''), 'admin'), 100);

    select id into v_short_id from public.writeoff_reasons where code = 'shortage';
    select id into v_surr_id  from public.writeoff_reasons where code = 'surplus';
    if v_short_id is null or v_surr_id is null then
        raise exception 'Системные причины shortage/surplus не найдены в справочнике — проверьте посев скрипта 31';
    end if;

    /* блокировка вариантов в детерминированном порядке (паттерн F23 —
       параллельные завершения/продажи выстраиваются в очередь, без deadlock) */
    for v_rec in
        select distinct ii.variant_id
          from public.inventory_items ii
         where ii.session_id = p_session_id
           and coalesce(ii.diff, 0) <> 0
         order by ii.variant_id
    loop
        perform 1 from public.product_variants where id = v_rec.variant_id for update;
    end loop;

    /* проведение: вариант (б) — БЕЗ guard на минус (предупреждение — модалка
       фронтенда до вызова; CHECK stock >= 0 снят скриптом 31) */
    for v_rec in
        select ii.id, ii.variant_id, ii.diff
          from public.inventory_items ii
         where ii.session_id = p_session_id
           and coalesce(ii.diff, 0) <> 0
         order by ii.variant_id, ii.id
    loop
        insert into public.writeoffs
            (variant_id, qty, reason_id, session_id, comment, changed_by)
        values
            (v_rec.variant_id, v_rec.diff,
             case when v_rec.diff < 0 then v_short_id else v_surr_id end,
             p_session_id,
             'Инвентаризация № ' || p_session_id,
             v_by);
        v_lines := v_lines + 1;
        if v_rec.diff < 0 then
            v_short := v_short + (-v_rec.diff);
        else
            v_surr := v_surr + v_rec.diff;
        end if;

        update public.product_variants
           set stock = stock + v_rec.diff
         where id = v_rec.variant_id
        returning stock into v_new;

        if v_new <= 0 then
            v_neg := v_neg || jsonb_build_object(
                'variant_id', v_rec.variant_id,
                'product', (select pr.name from public.product_variants pv
                             join public.products pr on pr.id = pv.product_id
                            where pv.id = v_rec.variant_id),
                'variant', (select pv.label from public.product_variants pv
                            where pv.id = v_rec.variant_id),
                'stock', v_new);
        end if;
    end loop;

    update public.inventory_sessions
       set status = 'done', finished_at = now()
     where id = p_session_id;

    /* сессия без расхождений завершается нулевой (Д2) */
    return jsonb_build_object(
        'ok', true,
        'writeoffs_created', v_lines,
        'shortages', v_short,
        'surpluses', v_surr,
        'negative_positions', v_neg);
end;
$$;

comment on function public.admin_finish_inventory_session is
    'Завершение сессии одной транзакцией (волна v0.20.0, Д5/Д6 — АН-21 вариант (б) «предупреждение с проведением», решение владельца 7.1 от 10.10.2026): по каждому ненулевому расхождению — строка writeoffs (qty = diff: «−» списание с причиной shortage / «+» излишек surplus, комментарий «Инвентаризация № X») + stock += diff БЕЗ запрета минуса (предупреждение — модалка фронтенда; защита витрины — условное списание create_order); FOR UPDATE в детерминированном порядке variant_id (F23); в ответе — сводка: writeoffs_created, shortages/surpluses (шт), negative_positions (уход в ноль/минус — для протокола); завершение — только роль «администратор» (7.3(б), до M2 — мок-гейт); повторное завершение/завершение отменённой — ошибка; расхождение считается от snapshot старта';

-- ----------------------------------------------------------------------------
-- 6. admin_create_writeoff — ручное списание/излишек вне сессии (Д7)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_create_writeoff(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_var     integer;
    v_qty     integer;
    v_reason  integer;
    v_comment text;
    v_by      text;
    v_stock   integer;
    v_id      integer;
begin
    if translate(coalesce(p->>'variant_id', ''), '0123456789', '') <> ''
       or coalesce(p->>'variant_id', '') = '' then
        raise exception 'Не указан вариант товара';
    end if;
    v_var := (p->>'variant_id')::integer;

    /* qty — целое, не ноль, по модулю ≤ 99999 (знак: «−» списание / «+» излишек) */
    if coalesce(p->>'qty', '') = ''
       or translate(replace(p->>'qty', '-', ''), '0123456789', '') <> ''
       or replace(p->>'qty', '-', '') = ''
       or length(replace(p->>'qty', '-', '')) > 5 then
        raise exception 'Количество: целое число, не ноль (−99999…99999)';
    end if;
    v_qty := (p->>'qty')::integer;
    if v_qty = 0 then
        raise exception 'Количество не может быть нулём (− списание / + излишек)';
    end if;
    if abs(v_qty) > 99999 then
        raise exception 'Количество: целое число, не ноль (−99999…99999)';
    end if;

    if translate(coalesce(p->>'reason_id', ''), '0123456789', '') <> ''
       or coalesce(p->>'reason_id', '') = '' then
        raise exception 'Не указана причина списания';
    end if;
    select id into v_reason
      from public.writeoff_reasons
     where id = (p->>'reason_id')::integer
       and is_active;
    if not found then
        raise exception 'Причина списания не найдена или неактивна';
    end if;

    v_comment := nullif(trim(coalesce(p->>'comment', '')), '');
    if v_comment is not null and length(v_comment) > 1000 then
        raise exception 'Комментарий: не более 1000 символов';
    end if;
    v_by := left(coalesce(nullif(trim(p->>'changed_by'), ''), 'admin'), 100);

    select stock into v_stock
      from public.product_variants
     where id = v_var
     for update;
    if not found then
        raise exception 'Вариант товара № % не найден', v_var;
    end if;

    /* guard ручных списаний СОХРАНЁН (Д5/Д7): минус — только через проведение
       инвентаризации; резерв не затрагивается — списание из свободных единиц */
    if v_qty < 0 and v_stock + v_qty < 0 then
        raise exception 'Недостаточно свободного остатка для списания: есть % шт., списывается % шт. (зарезервированные единицы не затрагиваются)', v_stock, -v_qty;
    end if;

    insert into public.writeoffs
        (variant_id, qty, reason_id, session_id, comment, changed_by)
    values
        (v_var, v_qty, v_reason, null, v_comment, v_by)
    returning id into v_id;

    update public.product_variants
       set stock = stock + v_qty
     where id = v_var;

    return jsonb_build_object('ok', true, 'writeoff_id', v_id);
end;
$$;

comment on function public.admin_create_writeoff is
    'Ручное списание/излишек вне инвентаризации (волна v0.20.0, Д7 — «да, без раздувания карточки товара»: кнопка в журнале «Списания» панели «Инвентаризация»): p = {variant_id, qty (≠0; «−» списание / «+» излишек), reason_id (активная из справочника), comment? ≤1000, changed_by?}; guard stock + qty >= 0 для списаний СОХРАНЁН — минус только через проведение инвентаризации (Д5)';

-- ----------------------------------------------------------------------------
-- 7. draft_inventory_bundle — данные панели «Инвентаризация» (Д9; грабля №6 —
--    один запрос на представление)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_inventory_bundle(p_session_id integer default null)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'sessions', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id',               s.id,
                    'scope',            s.scope,
                    'scope_categories', s.scope_categories,
                    'scope_names',      (select coalesce(jsonb_agg(c.name order by c.name), '[]'::jsonb)
                                          from public.categories c
                                         where s.scope = 'categories'
                                           and c.id::text in (select jsonb_array_elements_text(s.scope_categories))),
                    'plan_date',        s.plan_date,
                    'status',           s.status,
                    'participants',     s.participants,
                    'participant_names',(select coalesce(jsonb_agg(a.fio order by a.fio), '[]'::jsonb)
                                          from public.admin_users a
                                         where a.id::text in (select jsonb_array_elements_text(s.participants))),
                    'created_by',       s.created_by,
                    'started_at',       s.started_at,
                    'finished_at',      s.finished_at,
                    'created_at',       s.created_at,
                    'items_total',      (select count(*) from public.inventory_items ii
                                          where ii.session_id = s.id),
                    'items_counted',    (select count(*) from public.inventory_items ii
                                          where ii.session_id = s.id and ii.fact_qty is not null),
                    'discrepancies',    (select count(*) from public.inventory_items ii
                                          where ii.session_id = s.id and coalesce(ii.diff, 0) <> 0)
                 ) order by s.id desc), '[]'::jsonb)
                  from public.inventory_sessions s),
    'reasons',   (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', r.id, 'code', r.code, 'name', r.name,
                    'is_system', r.is_system, 'is_active', r.is_active,
                    'sort_order', r.sort_order
                 ) order by r.sort_order, r.id), '[]'::jsonb)
                  from public.writeoff_reasons r),
    'categories',(select coalesce(jsonb_agg(jsonb_build_object(
                    'id', c.id, 'name', c.name) order by c.name, c.id), '[]'::jsonb)
                  from public.categories c),
    'admins',    (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', a.id, 'fio', a.fio, 'role', a.role) order by a.fio, a.id), '[]'::jsonb)
                  from public.admin_users a
                 where a.is_active),
    'sheet',     case when p_session_id is null then null
                 else (select coalesce(jsonb_agg(jsonb_build_object(
                    'item_id',        ii.id,
                    'variant_id',     ii.variant_id,
                    'product_id',     pr.id,
                    'article',        pr.article,
                    'product',        pr.name,
                    'variant',        pv.label,
                    'system_qty',     ii.system_qty,
                    'reserved_qty',   ii.reserved_qty,
                    'quarantine_qty', ii.quarantine_qty,
                    'expected_qty',   ii.expected_qty,
                    'fact_qty',       ii.fact_qty,
                    'diff',           ii.diff,
                    'stock_now',      pv.stock,
                    'counted_by',     ii.counted_by,
                    'updated_at',     ii.updated_at
                 ) order by pr.name, pv.sort_order, pv.label, ii.id), '[]'::jsonb)
                  from public.inventory_items ii
                  join public.product_variants pv on pv.id = ii.variant_id
                  join public.products pr on pr.id = pv.product_id
                 where ii.session_id = p_session_id)
                 end
);
$$;

comment on function public.draft_inventory_bundle is
    'Бандл панели «Инвентаризация» (волна v0.20.0, Д9 — грабля №6, один запрос): без p_session_id — сессии (с агрегатами листа: всего/посчитано/расхождений, ФИО участников, имена категорий) + справочник причин + категории + активные админы (форма создания); с p_session_id — дополнительно sheet: лист (snapshot system/reserved/quarantine/expected + fact/diff + stock_now + товар/вариант/артикул)';

-- ----------------------------------------------------------------------------
-- 8. draft_writeoffs_bundle — журнал списаний + данные подвкладки
--    «Статистика → Списания» (Д8/Д9; паттерн draft_returns_bundle — лениво)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_writeoffs_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'writeoffs', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id',         w.id,
                    'created_at', w.created_at,
                    'variant_id', w.variant_id,
                    'product_id', pr.id,
                    'article',    pr.article,
                    'product',    pr.name,
                    'variant',    pv.label,
                    'price',      pr.price,          /* суммы — по текущей цене (Д8; в бою — исторические цены, fp №28) */
                    'qty',        w.qty,
                    'reason_id',  w.reason_id,
                    'reason',     coalesce(wr.name, '—'),
                    'reason_code', wr.code,
                    'session_id', w.session_id,
                    'comment',    w.comment,
                    'changed_by', w.changed_by
                 ) order by w.created_at desc, w.id desc), '[]'::jsonb)
                  from public.writeoffs w
                  join public.product_variants pv on pv.id = w.variant_id
                  join public.products pr on pr.id = pv.product_id
                  left join public.writeoff_reasons wr on wr.id = w.reason_id),
    'reasons',   (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', r.id, 'code', r.code, 'name', r.name,
                    'is_system', r.is_system, 'is_active', r.is_active,
                    'sort_order', r.sort_order
                 ) order by r.sort_order, r.id), '[]'::jsonb)
                  from public.writeoff_reasons r),
    'sessions',  (select coalesce(jsonb_agg(jsonb_build_object(
                    'id',            s.id,
                    'scope',         s.scope,
                    'plan_date',     s.plan_date,
                    'created_at',    s.created_at,
                    'started_at',    s.started_at,
                    'finished_at',   s.finished_at,
                    'writeoff_lines',(select count(*) from public.writeoffs w
                                       where w.session_id = s.id and w.qty < 0),
                    'writeoff_qty',  (select coalesce(sum(-w.qty), 0) from public.writeoffs w
                                       where w.session_id = s.id and w.qty < 0),
                    'surplus_lines', (select count(*) from public.writeoffs w
                                       where w.session_id = s.id and w.qty > 0),
                    'surplus_qty',   (select coalesce(sum(w.qty), 0) from public.writeoffs w
                                       where w.session_id = s.id and w.qty > 0)
                 ) order by s.id desc), '[]'::jsonb)
                  from public.inventory_sessions s
                 where s.status = 'done')
);
$$;

comment on function public.draft_writeoffs_bundle is
    'Журнал списаний + статистика одним RPC (волна v0.20.0, Д8/Д9 — подвкладка «Статистика → Списания» и журнал панели «Инвентаризация»; лениво — паттерн draft_returns_bundle): writeoffs (товар/вариант/артикул/текущая цена для сумм, qty ±, причина, автор, комментарий, session_id) + reasons + проведённые сессии с итогами (строк/шт списаний и излишков); суммы — по текущей цене товара (в бою — по закупочной и цене продажи на момент инвентаризации, fp №28)';

-- ----------------------------------------------------------------------------
-- 9. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select to_regprocedure('public.admin_create_inventory_session(jsonb)') is not null)  as f_create,   -- ждём t
    (select to_regprocedure('public.admin_start_inventory_session(integer,text)') is not null)  as f_start,    -- ждём t
    (select to_regprocedure('public.admin_cancel_inventory_session(integer,text)') is not null) as f_cancel,   -- ждём t
    (select to_regprocedure('public.admin_save_inventory_items(jsonb)') is not null)      as f_save,     -- ждём t
    (select to_regprocedure('public.admin_finish_inventory_session(integer,text)') is not null) as f_finish,   -- ждём t
    (select to_regprocedure('public.admin_create_writeoff(jsonb)') is not null)           as f_writeoff, -- ждём t
    (select to_regprocedure('public.draft_inventory_bundle(integer)') is not null)        as f_bundle,   -- ждём t
    (select to_regprocedure('public.draft_writeoffs_bundle()') is not null)               as f_wo_bundle, -- ждём t
    (select obj_description(oid, 'pg_proc') like 'v9%' from pg_proc
      where proname = 'create_order')                                                     as order_v9,   -- ждём t
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public')                                                         as func_count_28; -- ждём 28
-- Ожидаемая строка самопроверки (psql -At): t|t|t|t|t|t|t|t|t|28
