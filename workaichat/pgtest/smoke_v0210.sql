-- Смоук-тест волны v0.21.0 (скрипт 33: бейджи) — запуск на свежей базе
-- (baseline 01–05, 09 + инкременты 26–32 + 33). Сценарии S1–S8 приложения А
-- инструкции update-v0210.md; S6 (RLS под anon) и повторный прогон 33 (no-op) —
-- в драйвере run_v0210.py; S9 — статика фронтенда (node --check, grep) —
-- в драйвере/вручную. Результаты — строки 'PASS: …' / 'FAIL: …' в stdout
-- (psql -At).
\set ON_ERROR_STOP on

create temp table smoke_results (n serial, line text);

do $$
declare
    v_b_new  integer; v_b_hit integer; v_b_end integer;
    v_b_soon integer; v_b_pct integer;
    v_p1     integer;   -- товар с запасом (S4 RPC, S8 заказ)
    v_v1     integer;   -- его вариант со stock >= 2
    v_p_zero integer;   -- товар с нулевым остатком (S7, ответ 7.7)
    v_pay    integer; v_del integer;
    v_res    jsonb; v_bundle jsonb; v_items jsonb;
    v_n      integer; v_n2 integer; v_n3 integer;
    v_err    text;
begin
    select id into v_b_new  from badges where code = 'new';
    select id into v_b_hit  from badges where code = 'hit';
    select id into v_b_end  from badges where code = 'ending';
    select id into v_b_soon from badges where code = 'soon';
    select id into v_b_pct  from badges where code = 'percent';
    select id into v_pay from payment_methods where is_active order by id limit 1;
    select id into v_del from delivery_methods where is_active order by id limit 1;

    /* ---- S1: посев справочника ---- */
    select count(*) into v_n  from badges;
    select count(*) into v_n2 from badges where is_active;
    select count(*) into v_n3 from badges where is_system;
    if v_n = 5 and v_n2 = 5 and v_n3 = 1
       and (select is_system from badges where code = 'new')
       and (select name from badges where code = 'ending') = 'Заканчивается'
       and (select name from badges where code = 'percent') = '%'
       and (select sort_order from badges where code = 'new') = 1 then
        insert into smoke_results (line) values
            ('PASS: S1 посев — 5 бейджей (New системный sort 1, «Заканчивается», «%»), все активны');
    else
        insert into smoke_results (line) values
            ('FAIL: S1 badges=' || v_n || ' active=' || v_n2 || ' system=' || v_n3);
    end if;

    /* ---- S2: стартовое назначение «New» всем товарам (Д7) ---- */
    select count(*) into v_n  from products;
    select count(*) into v_n2 from product_badges pb
      join badges b on b.id = pb.badge_id where b.code = 'new';
    select count(*) into v_n3 from product_badges;
    if v_n2 = v_n and v_n3 = v_n then
        insert into smoke_results (line) values
            ('PASS: S2 «New» у всех товаров (' || v_n || '), лишних назначений нет');
    else
        insert into smoke_results (line) values
            ('FAIL: S2 products=' || v_n || ' new=' || v_n2 || ' total=' || v_n3);
    end if;

    /* цели: v_p1 — товар с запасом; v_p_zero — нулевой остаток (если в посеве
       нет — обнуляем второй товар: свежая база, сценарий детерминированный) */
    select p.id, pv.id into v_p1, v_v1
      from products p join product_variants pv on pv.product_id = p.id
     where p.is_active and pv.stock >= 2
     order by p.id, pv.id limit 1;
    select p.id into v_p_zero
      from products p
     where p.is_active and p.id <> v_p1
       and not exists (select 1 from product_variants pv
                        where pv.product_id = p.id and pv.stock > 0)
     order by p.id limit 1;
    if v_p_zero is null then
        select p.id into v_p_zero from products p
         where p.is_active and p.id <> v_p1
         order by p.id desc limit 1;
        update product_variants set stock = 0 where product_id = v_p_zero;
    end if;

    /* ---- S4: draft_save_product_badges — замена набора (Д3) ---- */
    v_res := draft_save_product_badges(jsonb_build_object(
        'product_id', v_p1, 'badge_ids', jsonb_build_array(v_b_hit, v_b_end)));
    select count(*) into v_n from product_badges where product_id = v_p1;
    if (v_res->>'ok')::boolean and (v_res->>'count')::int = 2 and v_n = 2
       and (select sort_order from product_badges
             where product_id = v_p1 and badge_id = v_b_hit) = 1
       and (select sort_order from product_badges
             where product_id = v_p1 and badge_id = v_b_end) = 2
       and not exists (select 1 from product_badges
                        where product_id = v_p1 and badge_id = v_b_new) then
        insert into smoke_results (line) values
            ('PASS: S4 замена набора [Хит, Заканчивается]: 2 строки sort 1/2, New снят');
    else
        insert into smoke_results (line) values
            ('FAIL: S4 res=' || coalesce(v_res::text, 'null') || ' rows=' || v_n);
    end if;

    /* дубли схлопываются; пустой массив — снять все (в т.ч. New — ответ 7.4) */
    v_res := draft_save_product_badges(jsonb_build_object(
        'product_id', v_p1, 'badge_ids', jsonb_build_array(v_b_soon)));
    v_res := draft_save_product_badges(jsonb_build_object(
        'product_id', v_p1, 'badge_ids', jsonb_build_array(v_b_hit, v_b_hit, v_b_end)));
    select count(*) into v_n from product_badges where product_id = v_p1;
    if (v_res->>'count')::int = 2 and v_n = 2 then
        v_res := draft_save_product_badges(jsonb_build_object(
            'product_id', v_p1, 'badge_ids', '[]'::jsonb));
        select count(*) into v_n from product_badges where product_id = v_p1;
        if (v_res->>'count')::int = 0 and v_n = 0 then
            insert into smoke_results (line) values
                ('PASS: S4 дубли схлопываются ([Хит,Хит,Заканчивается] → 2), пустой массив снимает все (7.4)');
        else
            insert into smoke_results (line) values ('FAIL: S4 пустой массив rows=' || v_n);
        end if;
    else
        insert into smoke_results (line) values
            ('FAIL: S4 дубли count=' || coalesce(v_res->>'count', '?') || ' rows=' || v_n);
    end if;
    /* восстанавливаем New у v_p1 */
    v_res := draft_save_product_badges(jsonb_build_object(
        'product_id', v_p1, 'badge_ids', jsonb_build_array(v_b_new)));

    /* ---- S4б: guard'ы RPC ---- */
    begin
        perform draft_save_product_badges(jsonb_build_object(
            'product_id', 999999, 'badge_ids', '[]'::jsonb));
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    if v_err not like '%Товар не найден%' then
        insert into smoke_results (line) values
            ('FAIL: S4б несуществующий товар err=' || coalesce(v_err, 'нет'));
    else
        update badges set is_active = false where code = 'percent';
        begin
            perform draft_save_product_badges(jsonb_build_object(
                'product_id', v_p1, 'badge_ids', jsonb_build_array(v_b_pct)));
            v_err := null;
        exception when others then v_err := sqlerrm;
        end;
        update badges set is_active = true where code = 'percent';
        if v_err not like '%не найден или неактивен%' then
            insert into smoke_results (line) values
                ('FAIL: S4б неактивный бейдж err=' || coalesce(v_err, 'нет'));
        else
            begin
                perform draft_save_product_badges(jsonb_build_object(
                    'product_id', v_p1, 'badge_ids', '["abc"]'::jsonb));
                v_err := null;
            exception when others then v_err := sqlerrm;
            end;
            /* после ошибки транзакция функции откатилась — New у v_p1 на месте */
            if v_err like '%не число%'
               and exists (select 1 from product_badges
                            where product_id = v_p1 and badge_id = v_b_new) then
                insert into smoke_results (line) values
                    ('PASS: S4б guard''ы — несуществующий товар / неактивный бейдж / id не число: читаемые ошибки, набор не повреждён');
            else
                insert into smoke_results (line) values
                    ('FAIL: S4б id не число err=' || coalesce(v_err, 'нет'));
            end if;
        end if;
    end if;

    /* ---- S5: draft_storefront_bundle v3 — состав ---- */
    v_bundle := draft_storefront_bundle();
    if (v_bundle ? 'badges') and (v_bundle ? 'product_badges')
       and jsonb_array_length(v_bundle->'badges') = 5
       and (v_bundle ? 'brand') and (v_bundle ? 'looks') and (v_bundle ? 'brands')
       and (v_bundle ? 'content') and (v_bundle ? 'payments') and (v_bundle ? 'products')
       and (v_bundle ? 'variants') and (v_bundle ? 'categories') and (v_bundle ? 'deliveries')
       and (v_bundle ? 'look_items') and (v_bundle ? 'return_reasons') then
        insert into smoke_results (line) values
            ('PASS: S5 бандл v3 — badges (5) + product_badges, все 11 v2-ключей на месте');
    else
        insert into smoke_results (line) values
            ('FAIL: S5 ключи=' || (select string_agg(k, ',') from jsonb_object_keys(v_bundle) k));
    end if;

    /* ---- S5б: неактивный бейдж не входит в бандл ---- */
    insert into product_badges (product_id, badge_id, sort_order)
    values (v_p1, v_b_hit, 5) on conflict do nothing;
    update badges set is_active = false where code = 'hit';
    v_bundle := draft_storefront_bundle();
    select count(*) into v_n from jsonb_array_elements(v_bundle->'product_badges') x
     where (x->>'badge_id')::int = v_b_hit;
    v_n2 := jsonb_array_length(v_bundle->'badges');
    update badges set is_active = true where code = 'hit';
    delete from product_badges where product_id = v_p1 and badge_id = v_b_hit;
    if v_n = 0 and v_n2 = 4 then
        insert into smoke_results (line) values
            ('PASS: S5б неактивный бейдж — вне бандла (badges 4, назначения отфильтрованы)');
    else
        insert into smoke_results (line) values
            ('FAIL: S5б hit_in_bundle=' || v_n || ' badges=' || v_n2);
    end if;

    /* ---- S7: «Скоро» на товар без остатка (ответ 7.7) ---- */
    v_res := draft_save_product_badges(jsonb_build_object(
        'product_id', v_p_zero, 'badge_ids', jsonb_build_array(v_b_soon, v_b_new)));
    v_bundle := draft_storefront_bundle();
    select count(*) into v_n from jsonb_array_elements(v_bundle->'product_badges') x
     where (x->>'product_id')::int = v_p_zero and (x->>'badge_id')::int = v_b_soon;
    if (v_res->>'count')::int = 2 and v_n = 1 then
        insert into smoke_results (line) values
            ('PASS: S7 «Скоро» на товар с нулевым остатком — назначение и бандл работают (7.7)');
    else
        insert into smoke_results (line) values
            ('FAIL: S7 count=' || coalesce(v_res->>'count', '?') || ' in_bundle=' || v_n);
    end if;

    /* ---- S8: регресс — create_order v9 и бандлы ---- */
    v_items := jsonb_build_array(jsonb_build_object(
        'product_id', v_p1, 'variant_id', v_v1, 'quantity', 1));
    begin
        v_res := create_order(jsonb_build_object(
            'customer_name', 'Бейдж Тест', 'customer_phone', '+7 999 333-00-01',
            'customer_email', 'badge@test.local', 'customer_address', 'Москва, Тестовая 5',
            'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
        v_err := null;
    exception when others then v_err := sqlerrm;
    end;
    if v_err is null
       and draft_admin_bundle() is not null and draft_assembly_bundle() is not null
       and draft_clients_bundle() is not null and draft_returns_bundle() is not null
       and draft_inventory_bundle() is not null and draft_writeoffs_bundle() is not null
       and draft_reserved_map() is not null then
        insert into smoke_results (line) values
            ('PASS: S8 регресс — create_order v9 штатно (бейджи не влияют), все бандлы исполняются');
    else
        insert into smoke_results (line) values
            ('FAIL: S8 err=' || coalesce(v_err, 'один из бандлов null'));
    end if;
end
$$;

select line from smoke_results order by n;
