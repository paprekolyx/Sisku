-- Смоук-тест волны v0.22.0 (скрипты 34–35: атрибуты по категориям,
-- кросс-сегменты клиентов) — запуск на свежей базе (baseline 01–05, 09
-- ревизии 2 + 34 + 35). Сценарии S1–S14 приложения А инструкции
-- update-v0220.md; S15 (RLS под anon) и повторный прогон 34/35 (no-op) —
-- в драйвере run_v0220.py; статика фронтенда — в драйвере. Результаты —
-- строки 'PASS: …' / 'FAIL: …' в stdout (psql -At).
\set ON_ERROR_STOP on

create temp table smoke_results (n serial, line text);

do $$
declare
    v_c1        integer;   -- категория «Верхняя одежда»
    v_c5        integer;   -- категория «Парфюмерия»
    v_p1        integer;   -- товар 1 (пальто, категория 1)
    v_p2        integer;   -- товар 2 (платье)
    v_attr_comp integer;   -- атрибут «Состав» категории 1
    v_attr_lin  integer;   -- атрибут «Подкладка» категории 1
    v_attr_test integer;   -- тестовый атрибут конструктора (S4–S10)
    v_b_new     integer;   -- бейдж «New»
    v_cl_vip    integer;   -- смоук-клиент VIP (11 заказов)
    v_cl_new    integer;   -- смоук-клиент с 1 заказом
    v_status    integer;
    v_res       jsonb;
    v_bundle    jsonb;
    v_stat      jsonb;
    v_prod      jsonb;
    v_n         integer;
    v_n2        integer;
    v_n3        integer;
    v_err       text;
begin
    select id into v_c1 from categories where name = 'Верхняя одежда';
    select id into v_c5 from categories where name = 'Парфюмерия';
    select id into v_p1 from products where article = '10001';
    select id into v_p2 from products where article = '10002';
    select id into v_attr_comp from category_attrs where category_id = v_c1 and code = 'composition';
    select id into v_attr_lin  from category_attrs where category_id = v_c1 and code = 'lining';
    select id into v_b_new     from badges where code = 'new';
    select id into v_status    from order_statuses where code = 'new';

    /* ---- S1: посев скрипта 34 — 53 атрибута, по категориям 9/9/8/9/12/6 ---- */
    declare
        v_by_cat text;
    begin
        select string_agg(cnt::text, '/' order by ord)
          into v_by_cat
          from (select v.ord, (select count(*) from category_attrs a
                                join categories c on c.id = a.category_id
                               where c.name = v.nm) as cnt
                  from (values (1, 'Верхняя одежда'), (2, 'Платья'), (3, 'Трикотаж'),
                               (4, 'Рубашки и блузы'), (5, 'Парфюмерия'), (6, 'Аксессуары'))
                       as v(ord, nm)) t;
        if (select count(*) from category_attrs) = 53
           and v_by_cat = '9/9/8/9/12/6' then
            insert into smoke_results (line) values
                ('PASS: S1 посев — 53 атрибута, по категориям 9/9/8/9/12/6');
        else
            insert into smoke_results (line) values
                ('FAIL: S1 attrs=' || (select count(*) from category_attrs) || ' by_cat=' || coalesce(v_by_cat, '?'));
        end if;
    end;

    /* ---- S2: флаги посева (Д2) — is_filterable 22 (все enum), show_in_list 11 ---- */
    select count(*) into v_n  from category_attrs where is_filterable;
    select count(*) into v_n2 from category_attrs where show_in_list;
    select count(*) into v_n3 from category_attrs where type = 'enum';
    if v_n = 22 and v_n2 = 11 and v_n3 = 22
       and not exists (select 1 from category_attrs
                        where (type = 'enum') <> is_filterable) then
        insert into smoke_results (line) values
            ('PASS: S2 флаги — filterable 22 (= все enum и только enum), show_in_list 11 (пометки «В списке» fp №14)');
    else
        insert into smoke_results (line) values
            ('FAIL: S2 filterable=' || v_n || ' in_list=' || v_n2 || ' enum=' || v_n3);
    end if;

    /* ---- S3: идемпотентность посева — дублей нет ---- */
    select count(*) into v_n from category_attrs;
    select count(*) into v_n2 from (select distinct category_id, code from category_attrs) t;
    if v_n = 53 and v_n2 = 53 then
        insert into smoke_results (line) values
            ('PASS: S3 посев без дублей — 53 = 53 distinct (category_id, code); полный повторный прогон 34 — в драйвере (no-op)');
    else
        insert into smoke_results (line) values
            ('FAIL: S3 rows=' || v_n || ' distinct=' || v_n2);
    end if;

    /* ---- S4: admin_save_category_attr — новый text-атрибут ---- */
    v_res := admin_save_category_attr(jsonb_build_object(
        'category_id', v_c1, 'code', 'Smoke_Test', 'name', 'Смоук-атрибут', 'type', 'text'));
    v_attr_test := (v_res->>'id')::int;
    select count(*) into v_n from category_attrs
     where id = v_attr_test and code = 'smoke_test' and name = 'Смоук-атрибут'
       and type = 'text' and is_active and category_id = v_c1;
    if (v_res->>'ok')::boolean and v_n = 1 then
        insert into smoke_results (line) values
            ('PASS: S4 admin_save_category_attr — новый text-атрибут создан (code нормализован в нижний регистр)');
    else
        insert into smoke_results (line) values
            ('FAIL: S4 res=' || coalesce(v_res::text, 'null') || ' row=' || v_n);
    end if;

    /* ---- S5: enum без значений — ошибка валидации ---- */
    begin
        v_res := admin_save_category_attr(jsonb_build_object(
            'category_id', v_c1, 'code', 'bad_enum', 'name', 'Плохой', 'type', 'enum'));
        v_err := null;
    exception when others then
        v_err := sqlerrm;
    end;
    if v_err is not null and v_err like '%хотя бы одно значение%' then
        insert into smoke_results (line) values
            ('PASS: S5 enum без значений — ошибка валидации: ' || v_err);
    else
        insert into smoke_results (line) values
            ('FAIL: S5 err=' || coalesce(v_err, 'нет ошибки — валидация не сработала'));
    end if;

    /* ---- S6: правка существующего — upsert по id, без новой строки ---- */
    select count(*) into v_n from category_attrs where category_id = v_c1;
    v_res := admin_save_category_attr(jsonb_build_object(
        'id', v_attr_test, 'category_id', v_c1, 'code', 'smoke_test',
        'name', 'Смоук-атрибут 2', 'type', 'text', 'sort_order', 99));
    select count(*) into v_n2 from category_attrs where category_id = v_c1;
    select count(*) into v_n3 from category_attrs
     where id = v_attr_test and name = 'Смоук-атрибут 2' and sort_order = 99;
    if (v_res->>'ok')::boolean and v_n = v_n2 and v_n3 = 1 then
        insert into smoke_results (line) values
            ('PASS: S6 правка по id — upsert без новой строки (name/sort_order обновлены)');
    else
        insert into smoke_results (line) values
            ('FAIL: S6 before=' || v_n || ' after=' || v_n2 || ' updated=' || v_n3);
    end if;

    /* ---- S7: draft_save_product_attrs — upsert значений, пустое — удаление ---- */
    v_res := draft_save_product_attrs(v_p1, jsonb_build_object(
        v_attr_comp::text, '  Шерсть 80%, кашемир 20%  ',
        v_attr_lin::text,  'Вискоза',
        v_attr_test::text, 'проба'));
    select count(*) into v_n from product_attrs where product_id = v_p1;
    select value into v_err from product_attrs
     where product_id = v_p1 and attr_id = v_attr_comp;
    v_res := draft_save_product_attrs(v_p1, jsonb_build_object(
        v_attr_test::text, '   '));
    select count(*) into v_n2 from product_attrs
     where product_id = v_p1 and attr_id = v_attr_test;
    if v_n = 3 and v_err = 'Шерсть 80%, кашемир 20%' and v_n2 = 0
       and (v_res->>'deleted')::int = 1 then
        insert into smoke_results (line) values
            ('PASS: S7 draft_save_product_attrs — upsert 3 значений (trim), пустое значение — удаление строки');
    else
        insert into smoke_results (line) values
            ('FAIL: S7 rows=' || v_n || ' comp=' || coalesce(v_err, '?') || ' after_empty=' || v_n2);
    end if;

    /* ---- S8: draft_attrs_bundle — активные атрибуты 6 категорий + значения ---- */
    v_bundle := draft_attrs_bundle();
    select count(*) into v_n  from jsonb_array_elements(v_bundle->'attrs') x;
    select count(distinct (x->>'category_id')::int) into v_n2
      from jsonb_array_elements(v_bundle->'attrs') x;
    select count(*) into v_n3 from jsonb_array_elements(v_bundle->'values') x
     where (x->>'product_id')::int = v_p1 and (x->>'attr_id')::int = v_attr_comp
       and x->>'value' = 'Шерсть 80%, кашемир 20%';
    if v_n = (select count(*) from category_attrs where is_active)
       and v_n >= 53 and v_n2 = 6 and v_n3 = 1 then
        insert into smoke_results (line) values
            ('PASS: S8 draft_attrs_bundle — все активные атрибуты (' || v_n || ') 6 категорий + значения товаров');
    else
        insert into smoke_results (line) values
            ('FAIL: S8 attrs=' || v_n || ' cats=' || v_n2 || ' value_found=' || v_n3);
    end if;

    /* ---- S9: draft_storefront_bundle v4 — attr_dict + attrs у товара + форма v3 ---- */
    v_bundle := draft_storefront_bundle();
    select count(*) into v_n from jsonb_array_elements(v_bundle->'attr_dict') x;
    select count(distinct (x->>'category_id')::int) into v_n2
      from jsonb_array_elements(v_bundle->'attr_dict') x;
    select count(*) into v_n3 from jsonb_array_elements(v_bundle->'products') x
     where (x->>'id')::int = v_p1
       and x->'attrs'->>(v_attr_comp::text) = 'Шерсть 80%, кашемир 20%';
    if v_n = (select count(*) from category_attrs where is_active)
       and v_n >= 53 and v_n2 = 6 and v_n3 = 1
       and (select count(*) from jsonb_array_elements(v_bundle->'badges') x) = 5
       and v_bundle ? 'product_badges' and v_bundle ? 'looks' and v_bundle ? 'brand'
       and v_bundle ? 'return_reasons' and v_bundle ? 'content'
       and v_bundle ? 'categories' and v_bundle ? 'variants'
       and v_bundle ? 'payments' and v_bundle ? 'deliveries'
       and v_bundle ? 'look_items' and v_bundle ? 'brands' then
        insert into smoke_results (line) values
            ('PASS: S9 бандл витрины v4 — attr_dict (' || v_n || '/6 категорий), attrs у товара, все ключи v3/v2 на месте');
    else
        insert into smoke_results (line) values
            ('FAIL: S9 dict=' || v_n || ' cats=' || v_n2 || ' prod_attrs=' || v_n3);
    end if;

    /* ---- S10: admin_delete_category_attr — каскад значений ---- */
    v_res := draft_save_product_attrs(v_p1, jsonb_build_object(v_attr_test::text, 'проба 2'));
    select count(*) into v_n from product_attrs where attr_id = v_attr_test;
    v_res := admin_delete_category_attr(v_attr_test);
    select count(*) into v_n2 from category_attrs where id = v_attr_test;
    select count(*) into v_n3 from product_attrs where attr_id = v_attr_test;
    if (v_res->>'ok')::boolean and v_n >= 1 and v_n2 = 0 and v_n3 = 0
       and (v_res->>'deleted_values')::int >= 1 then
        insert into smoke_results (line) values
            ('PASS: S10 admin_delete_category_attr — атрибут и значения товаров удалены каскадом');
    else
        insert into smoke_results (line) values
            ('FAIL: S10 before=' || v_n || ' attr_left=' || v_n2 || ' values_left=' || v_n3);
    end if;

    /* ---- S11: clients v4 — контрольный клиент (11 заказов): VIP И повторный ---- */
    insert into clients (full_name, phone) values ('Смоук Клиент VIP', '+7 999 000-22-01')
    returning id into v_cl_vip;
    insert into orders (customer_name, status_id, client_id, total, delivery_cost)
    select 'Смоук Клиент VIP', v_status, v_cl_vip, 50000, 0 from generate_series(1, 11);
    v_bundle := draft_clients_bundle();
    select x into v_stat from jsonb_array_elements(v_bundle->'stats') x
     where (x->>'client_id')::int = v_cl_vip;
    if v_stat->>'is_vip' = 'true' and v_stat->>'is_repeat' = 'true'
       and v_stat->>'is_new' = 'false' and v_stat->>'segment' = 'vip'
       and (v_stat->>'orders')::int = 11 then
        insert into smoke_results (line) values
            ('PASS: S11 клиенты v4 — 11 заказов: is_vip=t И is_repeat=t (пересечение), is_new=f, segment=vip');
    else
        insert into smoke_results (line) values
            ('FAIL: S11 stat=' || coalesce(v_stat::text, 'не найден'));
    end if;

    /* ---- S12: клиент с 1 заказом — новый, не повторный, не VIP ---- */
    insert into clients (full_name, phone) values ('Смоук Клиент Новый', '+7 999 000-22-02')
    returning id into v_cl_new;
    insert into orders (customer_name, status_id, client_id, total, delivery_cost)
    values ('Смоук Клиент Новый', v_status, v_cl_new, 1000, 0);
    v_bundle := draft_clients_bundle();
    select x into v_stat from jsonb_array_elements(v_bundle->'stats') x
     where (x->>'client_id')::int = v_cl_new;
    if v_stat->>'is_new' = 'true' and v_stat->>'is_repeat' = 'false'
       and v_stat->>'is_vip' = 'false' and v_stat->>'segment' = 'new'
       and v_bundle ? 'thresholds' then
        insert into smoke_results (line) values
            ('PASS: S12 клиент с 1 заказом — is_new=t, is_repeat=f, is_vip=f, segment=new; thresholds на месте');
    else
        insert into smoke_results (line) values
            ('FAIL: S12 stat=' || coalesce(v_stat::text, 'не найден'));
    end if;

    /* ---- S13: функции — явный список 33 проектных имён + комментарии v4 ---- */
    select count(*) into v_n from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = any (array[
        'draft_phone_key', 'draft_email_key', 'check_promo', 'create_order',
        'admin_set_status', 'admin_set_paid', 'track_order', 'draft_save_look',
        'create_return_request', 'admin_set_return_status', 'admin_set_return_refund',
        'admin_resolve_quarantine', 'admin_update_client',
        'admin_create_inventory_session', 'admin_start_inventory_session',
        'admin_cancel_inventory_session', 'admin_save_inventory_items',
        'admin_finish_inventory_session', 'admin_create_writeoff',
        'draft_save_product_badges',
        'draft_reserved_map', 'draft_admin_bundle', 'draft_assembly_bundle',
        'draft_clients_bundle', 'draft_storefront_bundle', 'draft_returns_bundle',
        'draft_client_card_bundle', 'draft_inventory_bundle', 'draft_writeoffs_bundle',
        'admin_save_category_attr', 'admin_delete_category_attr',
        'draft_save_product_attrs', 'draft_attrs_bundle']);
    select count(*) into v_n2 from pg_proc
     where proname in ('draft_clients_bundle', 'draft_storefront_bundle')
       and obj_description(oid, 'pg_proc') like 'v4%';
    if v_n = 33 and v_n2 = 2 then
        insert into smoke_results (line) values
            ('PASS: S13 функции — 33 проектных по явному списку (методика Д11), clients/storefront — v4');
    else
        insert into smoke_results (line) values
            ('FAIL: S13 funcs=' || v_n || ' v4_comments=' || v_n2);
    end if;

    /* ---- S14: регресс v0.21.0 — бейджи (RPC + справочник в бандле v4) ---- */
    v_res := draft_save_product_badges(jsonb_build_object(
        'product_id', v_p2, 'badge_ids', jsonb_build_array(v_b_new)));
    v_bundle := draft_storefront_bundle();
    select count(*) into v_n from jsonb_array_elements(v_bundle->'product_badges') x
     where (x->>'product_id')::int = v_p2 and (x->>'badge_id')::int = v_b_new;
    if (v_res->>'ok')::boolean and (v_res->>'count')::int = 1 and v_n = 1 then
        insert into smoke_results (line) values
            ('PASS: S14 регресс v0.21.0 — draft_save_product_badges штатно, назначения в бандле v4');
    else
        insert into smoke_results (line) values
            ('FAIL: S14 res=' || coalesce(v_res::text, 'null') || ' in_bundle=' || v_n);
    end if;

    /* ---- уборка смоук-данных ---- */
    delete from orders where client_id in (v_cl_vip, v_cl_new);
    delete from clients where id in (v_cl_vip, v_cl_new);
end
$$;

select line from smoke_results order by n;
