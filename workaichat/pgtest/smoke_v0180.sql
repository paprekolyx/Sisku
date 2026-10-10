-- Смоук-тест волны v0.18.0 (скрипты 28–29, create_order v9) — запуск на свежей базе
-- (baseline 01–05, 09 + 26 + 27 + 28 + 29). Сценарии S1–S6 приложения А
-- инструкции update-v0180.md; S7 (RLS под anon) и S8 (повторный прогон 28 —
-- no-op) выполняет драйвер workaichat/pgtest/run_v0180.py.
-- Результаты — строки 'PASS: …' / 'FAIL: …' в stdout (psql -At).
\set ON_ERROR_STOP on

create temp table smoke_results (n serial, line text);

do $$
declare
    v_pay      integer;
    v_del      integer;
    v_var      integer;
    v_prod     integer;
    v_items    jsonb;
    v_res      jsonb;
    v_c1       integer;
    v_c2       integer;
    v_cnt      integer;
    v_name     text;
    v_phone    text;
    v_bundle   jsonb;
    v_ok       boolean;
begin
    select id into v_pay from payment_methods where is_active order by id limit 1;
    select id into v_del from delivery_methods where is_active order by id limit 1;
    select t.variant_id, t.product_id into v_var, v_prod
      from (select id as variant_id, product_id
              from product_variants where stock > 0
             order by stock desc, id limit 1) t;
    v_items := jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'variant_id', v_var, 'quantity', 1));

    /* ---- S1: 3 заказа одного клиента — варианты имени ----
       (анти-спам «3 заказа / 10 минут» обходится откатом created_at —
       паттерн волны v0.15.0) */
    v_res := create_order(jsonb_build_object(
        'customer_name', 'Иван',
        'customer_phone', '+7 999 000-00-01',
        'customer_email', 's1@test.local',
        'customer_address', 'Москва, Тестовая 1',
        'payment_method_id', v_pay, 'delivery_method_id', v_del,
        'items', v_items));
    v_c1 := (v_res->>'client_id')::integer;

    update orders set created_at = created_at - interval '1 hour';

    v_res := create_order(jsonb_build_object(
        'customer_name', 'Иван П.',
        'customer_phone', '89990000001',           /* тот же номер, другое написание */
        'customer_email', 's1@test.local',
        'customer_address', 'Москва, Тестовая 1',
        'payment_method_id', v_pay, 'delivery_method_id', v_del,
        'items', v_items));
    if (v_res->>'client_id')::integer <> v_c1 then
        insert into smoke_results (line)
        values ('FAIL: S1 заказ 2 — клиент ' || (v_res->>'client_id') || ' вместо ' || v_c1);
    end if;

    update orders set created_at = created_at - interval '1 hour';

    v_res := create_order(jsonb_build_object(
        'customer_name', 'И. Петров',
        'customer_phone', '+7 999 000-00-01',
        'customer_email', 's1@test.local',
        'customer_address', 'Москва, Тестовая 1',
        'payment_method_id', v_pay, 'delivery_method_id', v_del,
        'items', v_items));

    select count(*) into v_cnt from clients where phone_key = '79990000001';
    if v_cnt = 1 then
        insert into smoke_results (line) values ('PASS: S1 три заказа — один клиент');
    else
        insert into smoke_results (line)
        values ('FAIL: S1 клиентов с ключом 79990000001: ' || v_cnt || ' (ожидался 1)');
    end if;

    select count(*) into v_cnt from client_name_history
      where client_id = v_c1 and source = 'order';
    if v_cnt = 3 then
        insert into smoke_results (line) values ('PASS: S1 варианты имени — 3 строки (order)');
    else
        insert into smoke_results (line)
        values ('FAIL: S1 история имён: ' || v_cnt || ' строк order (ожидалось 3)');
    end if;

    select full_name into v_name from clients where id = v_c1;
    if v_name = 'И. Петров' then
        insert into smoke_results (line) values ('PASS: S1 full_name — последний вариант');
    else
        insert into smoke_results (line)
        values ('FAIL: S1 full_name = ' || coalesce(v_name, 'null') || ' (ожидалось «И. Петров»)');
    end if;

    /* ---- S2: правка контакта админом → заказ на старый контакт = новый клиент ---- */
    perform admin_update_client(jsonb_build_object(
        'client_id', v_c1,
        'full_name', 'Петров Иван',
        'phone', '+7 999 000-00-02',
        'email', 's1@test.local',
        'note', 'смоук v0.18.0'));

    update orders set created_at = created_at - interval '1 hour';

    v_res := create_order(jsonb_build_object(
        'customer_name', 'Старый Телефон',
        'customer_phone', '+7 999 000-00-01',      /* старый телефон C1 */
        'customer_email', 's2-new@test.local',      /* новая почта */
        'customer_address', 'Москва, Тестовая 2',
        'payment_method_id', v_pay, 'delivery_method_id', v_del,
        'items', v_items));
    v_c2 := (v_res->>'client_id')::integer;
    if v_c2 is not null and v_c2 <> v_c1 then
        insert into smoke_results (line)
        values ('PASS: S2 заказ на старый контакт — новый клиент (' || v_c2 || ')');
    else
        insert into smoke_results (line)
        values ('FAIL: S2 клиент ' || coalesce(v_c2::text, 'null') || ' (ожидался новый, не ' || v_c1 || ')');
    end if;

    select count(*) into v_cnt from client_contact_history
      where client_id = v_c1 and type = 'phone' and action = 'invalidated'
        and value = '+7 999 000-00-01';
    if v_cnt = 1 then
        insert into smoke_results (line) values ('PASS: S2 старый телефон — «invalidated» в истории');
    else
        insert into smoke_results (line)
        values ('FAIL: S2 invalidated-строк старого телефона: ' || v_cnt || ' (ожидалась 1)');
    end if;

    /* ---- S5 (часть 1): сохранение карточки подтвердило имя ---- */
    select name_confirmed into v_ok from clients where id = v_c1;
    if v_ok then
        insert into smoke_results (line) values ('PASS: S5 сохранение карточки — name_confirmed = true');
    else
        insert into smoke_results (line) values ('FAIL: S5 name_confirmed не установлен');
    end if;

    /* ---- S3: слияние только по e-mail (новый телефон + текущая почта C1) ---- */
    update orders set created_at = created_at - interval '1 hour';

    v_res := create_order(jsonb_build_object(
        'customer_name', 'Другой Телефон',
        'customer_phone', '+7 999 000-00-03',      /* новый телефон */
        'customer_email', 's1@test.local',          /* текущая почта C1 */
        'customer_address', 'Москва, Тестовая 3',
        'payment_method_id', v_pay, 'delivery_method_id', v_del,
        'items', v_items));
    if (v_res->>'client_id')::integer = v_c1 then
        insert into smoke_results (line) values ('PASS: S3 слияние по e-mail — заказ у C1');
    else
        insert into smoke_results (line)
        values ('FAIL: S3 клиент ' || (v_res->>'client_id') || ' (ожидался ' || v_c1 || ')');
    end if;

    /* ---- Д3: телефон клиента не перезаписан заказом ---- */
    select phone into v_phone from clients where id = v_c1;
    if v_phone = '+7 999 000-00-02' then
        insert into smoke_results (line) values ('PASS: S3/Д3 телефон клиента не перезаписан заказом');
    else
        insert into smoke_results (line)
        values ('FAIL: S3/Д3 phone = ' || coalesce(v_phone, 'null') || ' (ожидался +7 999 000-00-02)');
    end if;

    select count(*) into v_cnt from client_contact_history
      where client_id = v_c1 and type = 'phone' and action = 'offered'
        and value = '+7 999 000-00-03';
    if v_cnt = 1 then
        insert into smoke_results (line) values ('PASS: S3 новый телефон заказа — «offered» в истории');
    else
        insert into smoke_results (line)
        values ('FAIL: S3 offered-строк: ' || v_cnt || ' (ожидалась 1)');
    end if;

    /* ---- S5 (часть 2): подтверждённое имя заказом не перезаписано ---- */
    select full_name into v_name from clients where id = v_c1;
    if v_name = 'Петров Иван' then
        insert into smoke_results (line) values ('PASS: S5 подтверждённое имя заказом не перезаписано');
    else
        insert into smoke_results (line)
        values ('FAIL: S5 full_name = ' || coalesce(v_name, 'null') || ' (ожидалось «Петров Иван»)');
    end if;

    select count(*) into v_cnt from client_name_history
      where client_id = v_c1 and source = 'admin';
    if v_cnt = 1 then
        insert into smoke_results (line) values ('PASS: S5 правка админа — вариант «admin» в истории');
    else
        insert into smoke_results (line)
        values ('FAIL: S5 admin-строк истории имён: ' || v_cnt || ' (ожидалась 1)');
    end if;

    /* ---- S4: консистентность пар email/email_key и phone/phone_key ---- */
    select count(*) into v_cnt from clients
      where (email is null) <> (email_key is null)
         or (email is not null and lower(email) <> email_key)
         or (phone is not null and phone_key is not null
             and public.draft_phone_key(phone) is distinct from phone_key);
    if v_cnt = 0 then
        insert into smoke_results (line) values ('PASS: S4 рассогласований email/email_key и phone/phone_key нет');
    else
        insert into smoke_results (line)
        values ('FAIL: S4 клиентов с рассогласованием пар: ' || v_cnt);
    end if;

    /* ---- S6: состав бандла карточки ---- */
    v_bundle := draft_client_card_bundle(v_c1);
    v_ok := (v_bundle->'client'->>'id')::integer = v_c1
        and jsonb_array_length(v_bundle->'orders') >= 3
        and jsonb_array_length(v_bundle->'names') >= 5
        and jsonb_array_length(v_bundle->'contacts') >= 4
        and (v_bundle->'orders'->0 ? 'status_name')
        and (v_bundle->'orders'->0 ? 'status_code')
        and (v_bundle->'orders'->0 ? 'is_paid')
        and jsonb_typeof(v_bundle->'orders'->0->'items') = 'array'
        and jsonb_array_length(v_bundle->'orders'->0->'items') >= 1
        and (v_bundle->'orders'->0->'items'->0 ? 'title_snapshot');
    if v_ok then
        insert into smoke_results (line)
        values ('PASS: S6 бандл карточки (client + names + contacts + orders с items)');
    else
        insert into smoke_results (line)
        values ('FAIL: S6 бандл: ' || left(coalesce(v_bundle::text, 'null'), 300));
    end if;
end
$$;

select line from smoke_results order by n;
