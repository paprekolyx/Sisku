-- Смоук-тест волны v0.20.0 (скрипты 31–32: инвентаризация и списания) — запуск
-- на свежей базе (baseline 01–05, 09 + 26–30 + 31 + 32). Сценарии S1–S12
-- приложения А инструкции update-v0200.md; S9 (RLS под anon) и повторный
-- прогон 31 (no-op) — в драйвере run_v0200.py. Результаты — строки
-- 'PASS: …' / 'FAIL: …' в stdout (psql -At).
\set ON_ERROR_STOP on

create temp table smoke_results (n serial, line text);

do $$
declare
    v_pay    integer;
    v_del    integer;
    v_v1     integer;   -- вариант с запасом (списания/излишки)
    v_p1     integer;
    v_cat1   integer;
    v_v2     integer;   -- второй вариант (излишек +3, позже карантин)
    v_p2     integer;
    v_v3     integer;   -- вариант для АН-21 (уход в минус)
    v_p3     integer;
    sA       integer;   -- сессия «всё» (S2–S5)
    sB       integer;   -- сессия «по категориям» (S3, параллельная; отмена S11)
    sC       integer;   -- сессия минуса (S6)
    sD       integer;   -- сессия выравнивания (S6б)
    sE       integer;   -- сессия для отмены из planned (S11)
    v_it     integer;   -- item_id
    v_res    jsonb;
    v_items  jsonb;
    v_b0     jsonb;
    v_bA     jsonb;
    v_bw     jsonb;
    v_n      integer;
    v_n2     integer;
    v_stock  integer;
    v_exp    integer;
    v_fact   integer;
    v_cat_cnt integer;
    v_err    text;
begin
    select id into v_pay from payment_methods where is_active order by id limit 1;
    select id into v_del from delivery_methods where is_active order by id limit 1;

    /* три варианта из РАЗНЫХ товаров с запасом остатка */
    select pv.id, pv.product_id, pr.category_id into v_v1, v_p1, v_cat1
      from product_variants pv join products pr on pr.id = pv.product_id
     where pv.stock >= 6 and pr.is_active
     order by pv.stock desc, pv.id limit 1;
    select pv.id, pv.product_id into v_v2, v_p2
      from product_variants pv join products pr on pr.id = pv.product_id
     where pv.stock >= 5 and pr.is_active and pv.product_id <> v_p1
     order by pv.stock desc, pv.id limit 1;
    select pv.id, pv.product_id into v_v3, v_p3
      from product_variants pv join products pr on pr.id = pv.product_id
     where pv.stock >= 2 and pr.is_active and pv.product_id not in (v_p1, v_p2)
     order by pv.id limit 1;

    /* ---- S1: посев справочника и снятие CHECK ---- */
    select count(*) into v_n from writeoff_reasons;
    select count(*) into v_n2 from writeoff_reasons where is_system and code in ('shortage', 'surplus');
    if v_n = 5 and v_n2 = 2
       and (select count(*) from writeoff_reasons where name ilike '%уценк%') = 0
       and (select count(*) from pg_constraint where conname = 'product_variants_stock_check') = 0 then
        insert into smoke_results (line) values ('PASS: S1 посев 5 причин (2 системные, без «Уценки»), CHECK stock снят');
    else
        insert into smoke_results (line) values ('FAIL: S1 причин=' || v_n || ' системных=' || v_n2);
    end if;

    /* ---- S2: создание сессии «всё» ---- */
    v_res := admin_create_inventory_session(jsonb_build_object('scope', 'all', 'created_by', 'smoke'));
    sA := (v_res->>'session_id')::int;
    select count(*) into v_n from inventory_items where session_id = sA;
    select expected_qty into v_exp from inventory_items where session_id = sA and variant_id = v_v1;
    select count(*) into v_n2
      from product_variants pv join products pr on pr.id = pv.product_id where pr.is_active;
    if (select status from inventory_sessions where id = sA) = 'planned'
       and (v_res->>'items_count')::int = v_n and v_n = v_n2
       and v_exp = (select stock from product_variants where id = v_v1) then
        insert into smoke_results (line) values ('PASS: S2 сессия planned, лист = ' || v_n || ' активных вариантов, expected = stock+резерв+карантин');
    else
        insert into smoke_results (line) values ('FAIL: S2 items=' || v_n || '/' || v_n2 || ' expected=' || coalesce(v_exp::text, 'null'));
    end if;

    /* ---- S3: параллельные сессии (7.3(а)) ---- */
    v_res := admin_start_inventory_session(sA, 'smoke');
    v_res := admin_create_inventory_session(jsonb_build_object(
        'scope', 'categories', 'category_ids', jsonb_build_array(v_cat1),
        'participant_ids', jsonb_build_array((select id from admin_users order by id limit 1)),
        'plan_date', '2026-10-20', 'created_by', 'smoke'));
    sB := (v_res->>'session_id')::int;
    v_res := admin_start_inventory_session(sB, 'smoke');
    select count(*) into v_n
      from inventory_items ii join product_variants pv on pv.id = ii.variant_id
      join products pr on pr.id = pv.product_id
     where ii.session_id = sB and pr.category_id <> v_cat1;
    begin
        perform admin_start_inventory_session(sA, 'smoke');
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    if (select count(*) from inventory_sessions where status = 'in_progress' and id in (sA, sB)) = 2
       and v_n = 0
       and (select count(*) from inventory_items where session_id = sB) > 0
       and v_err is not null then
        insert into smoke_results (line) values ('PASS: S3 две in_progress одновременно (без guard), лист B — только категория, повторный старт — ошибка');
    else
        insert into smoke_results (line) values ('FAIL: S3 err=' || coalesce(v_err, 'нет (ожидали ошибку)'));
    end if;

    /* ---- S4: факты и расхождения ---- */
    select id, expected_qty into v_it, v_exp from inventory_items where session_id = sA and variant_id = v_v1;
    v_res := admin_save_inventory_items(jsonb_build_object(
        'session_id', sA, 'changed_by', 'smoke',
        'items', jsonb_build_array(jsonb_build_object('item_id', v_it, 'fact_qty', v_exp - 2))));
    select id, expected_qty into v_it, v_exp from inventory_items where session_id = sA and variant_id = v_v2;
    v_res := admin_save_inventory_items(jsonb_build_object(
        'session_id', sA, 'changed_by', 'smoke',
        'items', jsonb_build_array(jsonb_build_object('item_id', v_it, 'fact_qty', v_exp + 3))));
    select diff into v_n from inventory_items where session_id = sA and variant_id = v_v1;
    select diff into v_n2 from inventory_items where session_id = sA and variant_id = v_v2;
    begin
        select id into v_it from inventory_items where session_id = sA and variant_id = v_v3;
        perform admin_save_inventory_items(jsonb_build_object(
            'session_id', sA,
            'items', jsonb_build_array(jsonb_build_object('item_id', v_it, 'fact_qty', -1))));
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    if v_n = -2 and v_n2 = 3 and v_err is not null then
        insert into smoke_results (line) values ('PASS: S4 diff пересчитан (−2/+3), fact_qty = −1 — ошибка валидации');
    else
        insert into smoke_results (line) values ('FAIL: S4 diff=' || coalesce(v_n::text,'?') || '/' || coalesce(v_n2::text,'?') || ' err=' || coalesce(v_err, 'нет'));
    end if;

    /* ---- S5: завершение — списание и излишек ---- */
    select stock into v_n from product_variants where id = v_v1;
    select stock into v_n2 from product_variants where id = v_v2;
    v_res := admin_finish_inventory_session(sA, 'smoke');
    select stock into v_fact from product_variants where id = v_v1;
    begin
        perform admin_finish_inventory_session(sA, 'smoke');
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    if (v_res->>'writeoffs_created')::int = 2
       and (v_res->>'shortages')::int = 2 and (v_res->>'surpluses')::int = 3
       and jsonb_array_length(v_res->'negative_positions') = 0
       and (select status from inventory_sessions where id = sA) = 'done'
       and (select count(*) from writeoffs where session_id = sA and variant_id = v_v1 and qty = -2
             and reason_id = (select id from writeoff_reasons where code = 'shortage')
             and comment = 'Инвентаризация № ' || sA) = 1
       and (select count(*) from writeoffs where session_id = sA and variant_id = v_v2 and qty = 3
             and reason_id = (select id from writeoff_reasons where code = 'surplus')) = 1
       and v_fact = v_n - 2
       and (select stock from product_variants where id = v_v2) = v_n2 + 3
       and v_err is not null then
        insert into smoke_results (line) values ('PASS: S5 завершение: 2 строки журнала (−2 shortage / +3 surplus), stock изменён, статус done, повторный finish — ошибка');
    else
        insert into smoke_results (line) values ('FAIL: S5 res=' || coalesce(v_res::text,'null') || ' stock=' || v_fact || ' err=' || coalesce(v_err,'нет'));
    end if;

    /* старт завершённой сессии — ошибка (Д2) */
    begin
        perform admin_start_inventory_session(sA, 'smoke');
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    if v_err is not null then
        insert into smoke_results (line) values ('PASS: S5б старт завершённой сессии — ошибка');
    else
        insert into smoke_results (line) values ('FAIL: S5б старт done-сессии не заблокирован');
    end if;

    /* ---- S6: АН-21 вариант (б) — заказ резервирует единицу, факт уводит stock в минус ---- */
    v_items := jsonb_build_array(jsonb_build_object(
        'product_id', v_p3, 'variant_id', v_v3, 'quantity', 1));
    v_res := create_order(jsonb_build_object(
        'customer_name', 'Инвентаризация Тест', 'customer_phone', '+7 999 222-00-01',
        'customer_email', 'inv-minus@test.local', 'customer_address', 'Москва, Тестовая 2',
        'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
    update orders set created_at = created_at - interval '1 hour';
    select stock into v_stock from product_variants where id = v_v3;

    v_res := admin_create_inventory_session(jsonb_build_object('scope', 'all', 'created_by', 'smoke'));
    sC := (v_res->>'session_id')::int;
    v_res := admin_start_inventory_session(sC, 'smoke');
    select id, expected_qty into v_it, v_exp from inventory_items where session_id = sC and variant_id = v_v3;
    v_res := admin_save_inventory_items(jsonb_build_object(
        'session_id', sC, 'changed_by', 'smoke',
        'items', jsonb_build_array(jsonb_build_object('item_id', v_it, 'fact_qty', 0))));
    v_res := admin_finish_inventory_session(sC, 'smoke');
    select stock into v_fact from product_variants where id = v_v3;
    begin
        v_items := jsonb_build_array(jsonb_build_object(
            'product_id', v_p3, 'variant_id', v_v3, 'quantity', 1));
        perform create_order(jsonb_build_object(
            'customer_name', 'Минус Заказ', 'customer_phone', '+7 999 222-00-02',
            'customer_email', 'inv-fail@test.local', 'customer_address', 'Москва, Тестовая 3',
            'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    if v_fact = -1
       and jsonb_array_length(v_res->'negative_positions') >= 1
       and (select count(*) from writeoffs where session_id = sC and variant_id = v_v3 and qty < 0) = 1
       and v_err like '%Недостаточно остатка%' then
        insert into smoke_results (line) values ('PASS: S6 проведение без запрета минуса: stock = −1, negative_positions в сводке, create_order — «Недостаточно остатка»');
    else
        insert into smoke_results (line) values ('FAIL: S6 stock=' || v_fact || ' res=' || coalesce(v_res::text,'null') || ' err=' || coalesce(v_err,'нет'));
    end if;

    /* ---- S12: ручное списание против минуса + бандл витрины отдаёт −1 как есть ---- */
    begin
        perform admin_create_writeoff(jsonb_build_object(
            'variant_id', v_v3, 'qty', -1,
            'reason_id', (select id from writeoff_reasons where code = 'defect'),
            'changed_by', 'smoke'));
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    select (e->>'stock')::int into v_n
      from jsonb_array_elements(draft_storefront_bundle()->'variants') e
     where (e->>'id')::int = v_v3;
    if v_err is not null and v_n = -1
       and (select stock from product_variants where id = v_v3) = -1 then
        insert into smoke_results (line) values ('PASS: S12 ручное списание при stock = −1 — ошибка (guard сохранён), бандл витрины отдаёт −1 как есть');
    else
        insert into smoke_results (line) values ('FAIL: S12 err=' || coalesce(v_err,'нет') || ' bundle_stock=' || coalesce(v_n::text,'?'));
    end if;

    /* ---- S6б: выравнивание остатка новой инвентаризацией — create_order снова ok ---- */
    v_res := admin_create_inventory_session(jsonb_build_object('scope', 'all', 'created_by', 'smoke'));
    sD := (v_res->>'session_id')::int;
    v_res := admin_start_inventory_session(sD, 'smoke');
    select id, expected_qty into v_it, v_exp from inventory_items where session_id = sD and variant_id = v_v3;
    v_res := admin_save_inventory_items(jsonb_build_object(
        'session_id', sD, 'changed_by', 'smoke',
        'items', jsonb_build_array(jsonb_build_object('item_id', v_it, 'fact_qty', v_exp + 5))));
    v_res := admin_finish_inventory_session(sD, 'smoke');
    select stock into v_fact from product_variants where id = v_v3;
    begin
        v_items := jsonb_build_array(jsonb_build_object(
            'product_id', v_p3, 'variant_id', v_v3, 'quantity', 1));
        v_res := create_order(jsonb_build_object(
            'customer_name', 'Выровненный Заказ', 'customer_phone', '+7 999 222-00-03',
            'customer_email', 'inv-ok@test.local', 'customer_address', 'Москва, Тестовая 4',
            'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
        update orders set created_at = created_at - interval '1 hour';
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    if v_fact = 4 and v_err is null then
        insert into smoke_results (line) values ('PASS: S6б выравнивание инвентаризацией: stock = 4, create_order снова ok');
    else
        insert into smoke_results (line) values ('FAIL: S6б stock=' || v_fact || ' err=' || coalesce(v_err,'нет'));
    end if;

    /* ---- S7: ручное списание ---- */
    select stock into v_stock from product_variants where id = v_v1;
    v_res := admin_create_writeoff(jsonb_build_object(
        'variant_id', v_v1, 'qty', -1,
        'reason_id', (select id from writeoff_reasons where code = 'defect'),
        'comment', 'Смоук: бой при примерке', 'changed_by', 'smoke'));
    select stock into v_fact from product_variants where id = v_v1;
    select count(*) into v_n from writeoffs
     where id = (v_res->>'writeoff_id')::int and session_id is null and variant_id = v_v1 and qty = -1;
    begin
        perform admin_create_writeoff(jsonb_build_object(
            'variant_id', v_v1, 'qty', -(v_fact + 1),
            'reason_id', (select id from writeoff_reasons where code = 'defect')));
        v_err := 'OVERDRAFT-OK';
    exception when others then v_err := sqlerrm;
    end;
    if v_err = 'OVERDRAFT-OK' then v_err := null; end if;
    declare
        v_err2 text;
        v_err3 text;
    begin
        begin
            perform admin_create_writeoff(jsonb_build_object(
                'variant_id', v_v1, 'qty', 0,
                'reason_id', (select id from writeoff_reasons where code = 'defect')));
            v_err2 := null;
        exception when others then v_err2 := sqlerrm;
        end;
        update writeoff_reasons set is_active = false where code = 'other';
        begin
            perform admin_create_writeoff(jsonb_build_object(
                'variant_id', v_v1, 'qty', -1,
                'reason_id', (select id from writeoff_reasons where code = 'other')));
            v_err3 := null;
        exception when others then v_err3 := sqlerrm;
        end;
        update writeoff_reasons set is_active = true where code = 'other';
        if v_fact = v_stock - 1 and v_n = 1
           and v_err is not null and v_err2 is not null and v_err3 is not null then
            insert into smoke_results (line) values ('PASS: S7 ручное списание: stock −1 + строка журнала (session null); сверх остатка / qty=0 / неактивная причина — ошибки');
        else
            insert into smoke_results (line) values ('FAIL: S7 stock=' || v_fact || ' rows=' || v_n ||
                ' overdraft=' || coalesce(v_err,'нет') || ' zero=' || coalesce(v_err2,'нет') || ' inactive=' || coalesce(v_err3,'нет'));
        end if;
    end;

    /* ---- S8: бандлы ---- */
    v_b0 := draft_inventory_bundle(null);
    v_bA := draft_inventory_bundle(sA);
    v_bw := draft_writeoffs_bundle();
    select count(*) into v_n from inventory_items where session_id = sA;
    if jsonb_array_length(v_b0->'sessions') >= 4
       and jsonb_array_length(v_b0->'reasons') = 5
       and jsonb_array_length(v_b0->'categories') = (select count(*) from categories)
       and jsonb_array_length(v_b0->'admins') >= 1
       and jsonb_typeof(v_b0->'sheet') = 'null'
       and jsonb_array_length(v_bA->'sheet') = v_n
       and (select count(*) from jsonb_array_elements(v_bA->'sheet') e
             where (e->>'variant_id')::int = v_v1 and (e->>'diff')::int = -2
               and (e->>'fact_qty') is not null) = 1
       and jsonb_array_length(v_bw->'writeoffs') >= 5
       and jsonb_array_length(v_bw->'reasons') = 5
       and (select count(*) from jsonb_array_elements(v_bw->'sessions') e
             where (e->>'id')::int = sA and (e->>'writeoff_qty')::int = 2
               and (e->>'surplus_qty')::int = 3) = 1 then
        insert into smoke_results (line) values ('PASS: S8 бандлы: inventory (без id — сессии/причины/категории/админы; с id — лист c fact/diff), writeoffs (журнал/причины/итоги сессий)');
    else
        insert into smoke_results (line) values ('FAIL: S8 состав бандлов: sessions=' || jsonb_array_length(v_b0->'sessions') ||
            ' sheet=' || coalesce(jsonb_array_length(v_bA->'sheet')::text,'null') ||
            ' wo=' || coalesce(jsonb_array_length(v_bw->'writeoffs')::text,'null'));
    end if;

    /* ---- S10: регресс карантина (осмотр не пишет в журнал списаний) ---- */
    update product_variants set quarantine_qty = 2 where id = v_v2;
    select count(*) into v_n from writeoffs;
    select stock into v_stock from product_variants where id = v_v2;
    v_res := admin_resolve_quarantine(v_v2, 1, 'restock', 'smoke');
    v_res := admin_resolve_quarantine(v_v2, 1, 'writeoff', 'smoke');
    select count(*) into v_n2 from writeoffs;
    select stock, quarantine_qty into v_fact, v_exp from product_variants where id = v_v2;
    if v_n2 = v_n and v_fact = v_stock + 1 and v_exp = 0 then
        insert into smoke_results (line) values ('PASS: S10 регресс карантина: restock/writeoff работают, журнал writeoffs не затрагивается (движения карантина — fp №3b)');
    else
        insert into smoke_results (line) values ('FAIL: S10 journal=' || v_n || '→' || v_n2 || ' stock=' || v_fact || ' quar=' || v_exp);
    end if;

    /* ---- S11: отмена сессии (Д2) ---- */
    v_res := admin_create_inventory_session(jsonb_build_object('scope', 'all', 'created_by', 'smoke'));
    sE := (v_res->>'session_id')::int;
    v_res := admin_cancel_inventory_session(sE, 'smoke');
    /* B: факт с расхождением → отмена; факты сохранены, списаний нет, stock не изменён */
    select id, expected_qty into v_it, v_exp from inventory_items where session_id = sB and variant_id = v_v1;
    v_res := admin_save_inventory_items(jsonb_build_object(
        'session_id', sB, 'changed_by', 'smoke',
        'items', jsonb_build_array(jsonb_build_object('item_id', v_it, 'fact_qty', v_exp + 7))));
    select stock into v_stock from product_variants where id = v_v1;
    select count(*) into v_n from writeoffs;
    v_res := admin_cancel_inventory_session(sB, 'smoke');
    select count(*) into v_n2 from writeoffs;
    begin
        perform admin_cancel_inventory_session(sA, 'smoke');
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    declare
        v_err2 text;
    begin
        begin
            perform admin_finish_inventory_session(sB, 'smoke');
            v_err2 := null;
        exception when others then v_err2 := sqlerrm;
        end;
        if (select status from inventory_sessions where id = sE) = 'cancelled'
           and (select status from inventory_sessions where id = sB) = 'cancelled'
           and (select finished_at from inventory_sessions where id = sB) is not null
           and (select fact_qty from inventory_items where session_id = sB and variant_id = v_v1) = v_exp + 7
           and v_n2 = v_n
           and (select stock from product_variants where id = v_v1) = v_stock
           and v_err is not null and v_err2 is not null then
            insert into smoke_results (line) values ('PASS: S11 отмена: из planned и из in_progress (факты сохранены, списаний нет, stock не изменён); из done — ошибка; finish отменённой — ошибка');
        else
            insert into smoke_results (line) values ('FAIL: S11 done-cancel=' || coalesce(v_err,'нет') || ' cancelled-finish=' || coalesce(v_err2,'нет') || ' journal=' || v_n || '→' || v_n2);
        end if;
    end;
end
$$;

select line from smoke_results order by n;
