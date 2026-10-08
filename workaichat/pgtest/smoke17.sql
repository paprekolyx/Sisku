-- Смоук-тест волны v0.17.0 (baseline + 26 + 27) — запуск на sisku_b
-- Результаты — строки 'PASS: …' / 'FAIL: …' в stdout (psql -At).
\set ON_ERROR_STOP on

create temp table smoke_results (n serial, line text);

do $$
declare
    v_ord      integer;
    v_ord2     integer;
    v_ord3     integer;
    v_var      integer;
    v_prod     integer;
    v_stock0   integer;
    v_stock1   integer;
    v_req      integer;
    v_quar     integer;
    v_status   text;
    v_res      jsonb;
    v_msg      text;
    v_ok       boolean;
    v_long     text := repeat('а', 1001);
    v_edge     text := repeat('б', 1000);
begin
    select id, product_id, stock into v_var, v_prod, v_stock0
      from product_variants where stock > 0 order by id limit 1;

    -- 1. Счастливый заказ (лимиты не мешают)
    select (create_order(jsonb_build_object(
        'customer_name', 'Тест Тестов',
        'customer_phone', '+7 999 000-00-01',
        'customer_email', 'smoke1@example.com',
        'customer_address', 'Москва, ул. Тестовая, 1',
        'comment', 'смоук волны 17',
        'payment_method_id', 1,
        'delivery_method_id', 2,
        'items', jsonb_build_array(jsonb_build_object(
            'variant_id', v_var, 'product_id', v_prod, 'quantity', 1))
    )))->>'order_id' into v_ord;
    if v_ord is not null then
        insert into smoke_results (line) values ('PASS: заказ создан (id ' || v_ord || ')');
    else
        insert into smoke_results (line) values ('FAIL: заказ не создан');
    end if;

    select stock into v_stock1 from product_variants where id = v_var;
    insert into smoke_results (line) values (
        case when v_stock1 = v_stock0 - 1
             then 'PASS: остаток списан (' || v_stock0 || '→' || v_stock1 || ')'
             else 'FAIL: остаток ' || v_stock0 || '→' || v_stock1 end);

    -- 2. Статусная цепочка до «Отправлен»
    perform admin_set_status(v_ord, 'confirmed', null, 'смоук');
    perform admin_set_status(v_ord, 'packing', null, 'смоук');
    perform admin_set_status(v_ord, 'shipped', null, 'смоук');
    select code into v_status from order_statuses s
      join orders o on o.status_id = s.id where o.id = v_ord;
    insert into smoke_results (line) values (
        case when v_status = 'shipped' then 'PASS: статусная цепочка → shipped'
             else 'FAIL: статус ' || v_status end);

    -- 3. Заявка на возврат: неверный код → отказ
    begin
        perform create_return_request(jsonb_build_object(
            'order_id', v_ord, 'code', '0000', 'reason_id', 1, 'comment', 'тест'));
        insert into smoke_results (line) values ('FAIL: заявка с неверным кодом прошла');
    exception when others then
        insert into smoke_results (line) values ('PASS: неверный код отклонён (' || sqlerrm || ')');
    end;

    -- 4. Заявка с верным кодом (хвост телефона 0001)
    select (create_return_request(jsonb_build_object(
        'order_id', v_ord, 'code', '0001', 'reason_id', 1,
        'comment', 'не подошёл размер')))->>'request_id' into v_req;
    if v_req is null then
        select id into v_req from return_requests where order_id = v_ord;
    end if;
    insert into smoke_results (line) values (
        case when v_req is not null then 'PASS: заявка создана (id ' || v_req || ')'
             else 'FAIL: заявка не создана' end);

    -- 5. Антиспам: повторная незакрытая заявка → отказ
    begin
        perform create_return_request(jsonb_build_object(
            'order_id', v_ord, 'code', '0001', 'reason_id', 2, 'comment', 'дубль'));
        insert into smoke_results (line) values ('FAIL: дубль заявки прошёл');
    exception when others then
        insert into smoke_results (line) values ('PASS: дубль заявки отклонён');
    end;

    -- 6. Товар вернулся на склад → заказ «Возврат», единицы в карантин
    perform admin_set_return_status(v_req, 'returned_to_stock', null, 'смоук');
    select code into v_status from order_statuses s
      join orders o on o.status_id = s.id where o.id = v_ord;
    select quarantine_qty, stock into v_quar, v_stock1
      from product_variants where id = v_var;
    insert into smoke_results (line) values (
        case when v_status = 'returned' and v_quar = 1
             then 'PASS: возврат → карантин (quarantine=1, stock=' || v_stock1 || ')'
             else 'FAIL: status=' || v_status || ' quarantine=' || v_quar end);

    -- 7. Проверена → resolved_at; деньги возвращены
    perform admin_set_return_status(v_req, 'verified', 'осмотр пройден', 'смоук');
    perform admin_set_return_refund(v_req, true, 'чек 123', 'смоук');
    select resolved_at is not null and refund_paid into v_ok
      from return_requests where id = v_req;
    insert into smoke_results (line) values (
        case when v_ok then 'PASS: verified + refund (resolved_at заполнен)'
             else 'FAIL: verified/refund' end);

    -- 8. Осмотр карантина: вернуть в продажу
    perform admin_resolve_quarantine(v_var, 1, 'restock', 'смоук');
    select quarantine_qty, stock into v_quar, v_stock1
      from product_variants where id = v_var;
    insert into smoke_results (line) values (
        case when v_quar = 0 and v_stock1 = v_stock0
             then 'PASS: restock из карантина (stock=' || v_stock1 || ')'
             else 'FAIL: quarantine=' || v_quar || ' stock=' || v_stock1 end);

    -- 9. Отмена → остаток возвращается в stock (регресс)
    select (create_order(jsonb_build_object(
        'customer_name', 'Отмена Тестова',
        'customer_phone', '+7 999 000-00-02',
        'customer_email', 'smoke2@example.com',
        'customer_address', 'Москва, ул. Тестовая, 2',
        'payment_method_id', 1, 'delivery_method_id', 1,
        'items', jsonb_build_array(jsonb_build_object(
            'variant_id', v_var, 'product_id', v_prod, 'quantity', 1))
    )))->>'order_id' into v_ord2;
    perform admin_set_status(v_ord2, 'cancelled', 'смоук отмены', 'смоук');
    select stock into v_stock1 from product_variants where id = v_var;
    insert into smoke_results (line) values (
        case when v_stock1 = v_stock0
             then 'PASS: отмена вернула остаток (' || v_stock1 || ')'
             else 'FAIL: после отмены stock=' || v_stock1 || ' (жду ' || v_stock0 || ')' end);

    -- 10. Лимит 1000: комментарий 1001 → отказ (v8)
    begin
        perform create_order(jsonb_build_object(
            'customer_name', 'Лимит Тестов',
            'customer_phone', '+7 999 000-00-03',
            'customer_email', 'smoke3@example.com',
            'customer_address', 'Москва',
            'comment', v_long,
            'payment_method_id', 1, 'delivery_method_id', 1,
            'items', jsonb_build_array(jsonb_build_object(
                'variant_id', v_var, 'product_id', v_prod, 'quantity', 1))));
        insert into smoke_results (line) values ('FAIL: заказ с комментарием 1001 прошёл');
    exception when others then
        v_msg := sqlerrm;
        insert into smoke_results (line) values (
            case when v_msg like '%не более 1000 символов%'
                 then 'PASS: лимит комментария 1000 (' || v_msg || ')'
                 else 'FAIL: другая ошибка: ' || v_msg end);
    end;

    -- 11. Лимит 1000: имя 1001 → отказ; граница 1000 → проходит
    begin
        perform create_order(jsonb_build_object(
            'customer_name', v_long,
            'customer_phone', '+7 999 000-00-04',
            'customer_email', 'smoke4@example.com',
            'customer_address', 'Москва',
            'payment_method_id', 1, 'delivery_method_id', 1,
            'items', jsonb_build_array(jsonb_build_object(
                'variant_id', v_var, 'product_id', v_prod, 'quantity', 1))));
        insert into smoke_results (line) values ('FAIL: заказ с именем 1001 прошёл');
    exception when others then
        insert into smoke_results (line) values (
            case when sqlerrm like '%не более 1000 символов%'
                 then 'PASS: лимит имени 1000'
                 else 'FAIL: другая ошибка: ' || sqlerrm end);
    end;

    select (create_order(jsonb_build_object(
        'customer_name', 'Граница Тестова',
        'customer_phone', '+7 999 000-00-05',
        'customer_email', 'smoke5@example.com',
        'customer_address', 'Москва',
        'comment', v_edge,
        'payment_method_id', 1, 'delivery_method_id', 1,
        'items', jsonb_build_array(jsonb_build_object(
            'variant_id', v_var, 'product_id', v_prod, 'quantity', 1))
    )))->>'order_id' into v_ord3;
    insert into smoke_results (line) values (
        case when v_ord3 is not null then 'PASS: граница 1000 символов проходит'
             else 'FAIL: граница 1000 не прошла' end);

    -- 12. Промокод: границы дат в Europe/Moscow (v2)
    insert into promo_codes (code, discount_type, discount_value, min_order_amount,
                             valid_from, valid_until, usage_limit, used_count, is_active)
    values ('SMOKE17', 'percent', 10, 0,
            (now() at time zone 'Europe/Moscow')::date,
            (now() at time zone 'Europe/Moscow')::date, 10, 0, true);
    select check_promo('SMOKE17', 1000) into v_res;
    insert into smoke_results (line) values (
        case when (v_res->>'ok')::boolean then 'PASS: промокод действует в московскую дату'
             else 'FAIL: check_promo ' || v_res::text end);

    -- 13. Бандлы читаются
    select draft_storefront_bundle() ? 'return_reasons' into v_ok;
    insert into smoke_results (line) values (
        case when v_ok then 'PASS: storefront-бандл с return_reasons'
             else 'FAIL: storefront-бандл' end);
    perform draft_returns_bundle();
    perform draft_admin_bundle();
    perform draft_assembly_bundle();
    perform draft_clients_bundle();
    perform draft_reserved_map();
    insert into smoke_results (line) values ('PASS: все бандлы вызываются');

    -- 14. Скрипт 27: пути .webp в данных
    select count(*) = 8 into v_ok from products
      where image_url like 'assets/img/products/%.webp';
    insert into smoke_results (line) values (
        case when v_ok then 'PASS: 8 товаров с .webp'
             else 'FAIL: webp-товаров не 8' end);
end $$;

select line from smoke_results order by n;
