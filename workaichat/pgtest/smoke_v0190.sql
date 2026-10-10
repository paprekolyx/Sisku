-- Смоук-тест волны v0.19.0 (скрипт 30, draft_clients_bundle v3) — запуск на свежей базе
-- (baseline 01–05, 09 + 26–29 + 30). Сценарии S1–S9 приложения А инструкции
-- update-v0190.md; S1 частично (73 ключа) — в самопроверке скрипта 30 и
-- драйвере run_v0190.py (повторный прогон — ключей не прибавляется).
-- Результаты — строки 'PASS: …' / 'FAIL: …' в stdout (psql -At).
\set ON_ERROR_STOP on

create temp table smoke_results (n serial, line text);

do $$
declare
    v_pay    integer;
    v_del    integer;
    v_var    integer[];
    v_prod   integer[];
    v_items  jsonb;
    v_res    jsonb;
    v_i      integer := 0;
    c_new    integer;
    c_rep    integer;
    c_vip    integer;
    c_sum    integer;
    c_dor    integer;
    c_edge   integer;
    v_b      jsonb;
    v_st     jsonb;
    v_th     jsonb;
    v_seg    text;
    v_dor    boolean;
begin
    select id into v_pay from payment_methods where is_active order by id limit 1;
    select id into v_del from delivery_methods where is_active order by id limit 1;
    select array_agg(variant_id order by rn), array_agg(product_id order by rn)
      into v_var, v_prod
      from (select id as variant_id, product_id, row_number() over (order by stock desc, id) as rn
              from product_variants where stock > 5 limit 2) t;

    /* вспомогательный заказ: чередует варианты (остатки), откатывает даты
       (анти-спам «3 заказа / 10 минут» — паттерн волны v0.15.0) */
    -- S2: «новый» — 1 заказ
    v_i := v_i + 1;
    v_items := jsonb_build_array(jsonb_build_object(
        'product_id', v_prod[1 + (v_i % 2)], 'variant_id', v_var[1 + (v_i % 2)], 'quantity', 1));
    v_res := create_order(jsonb_build_object(
        'customer_name', 'Сегмент Новый', 'customer_phone', '+7 999 111-00-01',
        'customer_email', 'seg-new@test.local', 'customer_address', 'Москва, Тестовая 1',
        'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
    c_new := (v_res->>'client_id')::integer;
    update orders set created_at = created_at - interval '1 hour';

    -- S3: «повторный» — 2 заказа
    for k in 1..2 loop
        v_i := v_i + 1;
        v_items := jsonb_build_array(jsonb_build_object(
            'product_id', v_prod[1 + (v_i % 2)], 'variant_id', v_var[1 + (v_i % 2)], 'quantity', 1));
        v_res := create_order(jsonb_build_object(
            'customer_name', 'Сегмент Повторный', 'customer_phone', '+7 999 111-00-02',
            'customer_email', 'seg-rep@test.local', 'customer_address', 'Москва, Тестовая 2',
            'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
        c_rep := (v_res->>'client_id')::integer;
        update orders set created_at = created_at - interval '1 hour';
    end loop;

    -- S4: VIP по количеству — 5 заказов (порог vip_orders_min = 5)
    for k in 1..5 loop
        v_i := v_i + 1;
        v_items := jsonb_build_array(jsonb_build_object(
            'product_id', v_prod[1 + (v_i % 2)], 'variant_id', v_var[1 + (v_i % 2)], 'quantity', 1));
        v_res := create_order(jsonb_build_object(
            'customer_name', 'Сегмент ВИП', 'customer_phone', '+7 999 111-00-03',
            'customer_email', 'seg-vip@test.local', 'customer_address', 'Москва, Тестовая 3',
            'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
        c_vip := (v_res->>'client_id')::integer;
        update orders set created_at = created_at - interval '1 hour';
    end loop;

    -- S5 (подготовка): клиент с 2 заказами — при пороге 100000 ещё не VIP по сумме
    for k in 1..2 loop
        v_i := v_i + 1;
        v_items := jsonb_build_array(jsonb_build_object(
            'product_id', v_prod[1 + (v_i % 2)], 'variant_id', v_var[1 + (v_i % 2)], 'quantity', 1));
        v_res := create_order(jsonb_build_object(
            'customer_name', 'Сегмент Сумма', 'customer_phone', '+7 999 111-00-04',
            'customer_email', 'seg-sum@test.local', 'customer_address', 'Москва, Тестовая 4',
            'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
        c_sum := (v_res->>'client_id')::integer;
        update orders set created_at = created_at - interval '1 hour';
    end loop;

    -- «уснул» — 1 заказ (даты откатим на 91 день ниже)
    v_i := v_i + 1;
    v_items := jsonb_build_array(jsonb_build_object(
        'product_id', v_prod[1 + (v_i % 2)], 'variant_id', v_var[1 + (v_i % 2)], 'quantity', 1));
    v_res := create_order(jsonb_build_object(
        'customer_name', 'Сегмент Уснувший', 'customer_phone', '+7 999 111-00-05',
        'customer_email', 'seg-dor@test.local', 'customer_address', 'Москва, Тестовая 5',
        'payment_method_id', v_pay, 'delivery_method_id', v_del, 'items', v_items));
    c_dor := (v_res->>'client_id')::integer;

    /* ---- бандл №1: дефолтные пороги — new / repeat / vip(5) / sum-rePEAT ---- */
    v_b := draft_clients_bundle();
    v_th := v_b->'thresholds';
    if (v_th->>'vip_orders_min')::int = 5 and (v_th->>'vip_sum_min')::int = 100000
       and (v_th->>'dormant_days')::int = 90 then
        insert into smoke_results (line) values ('PASS: S1 thresholds — дефолты 5 / 100000 / 90');
    else
        insert into smoke_results (line) values ('FAIL: S1 thresholds = ' || coalesce(v_th::text, 'null'));
    end if;

    select s->>'segment', (s->>'is_dormant')::boolean into v_seg, v_dor
      from jsonb_array_elements(v_b->'stats') s where (s->>'client_id')::int = c_new;
    if v_seg = 'new' and not v_dor then
        insert into smoke_results (line) values ('PASS: S2 один заказ — segment «new»');
    else
        insert into smoke_results (line) values ('FAIL: S2 segment=' || coalesce(v_seg,'null'));
    end if;

    select s->>'segment' into v_seg from jsonb_array_elements(v_b->'stats') s
      where (s->>'client_id')::int = c_rep;
    if v_seg = 'repeat' then
        insert into smoke_results (line) values ('PASS: S3 два заказа — segment «repeat»');
    else
        insert into smoke_results (line) values ('FAIL: S3 segment=' || coalesce(v_seg,'null'));
    end if;

    select s->>'segment' into v_seg from jsonb_array_elements(v_b->'stats') s
      where (s->>'client_id')::int = c_vip;
    if v_seg = 'vip' then
        insert into smoke_results (line) values ('PASS: S4 пять заказов — segment «vip» (по количеству)');
    else
        insert into smoke_results (line) values ('FAIL: S4 segment=' || coalesce(v_seg,'null'));
    end if;

    select s->>'segment' into v_seg from jsonb_array_elements(v_b->'stats') s
      where (s->>'client_id')::int = c_sum;
    if v_seg = 'repeat' then
        insert into smoke_results (line) values ('PASS: S4б два заказа до порога суммы — «repeat» (не VIP)');
    else
        insert into smoke_results (line) values ('FAIL: S4б segment=' || coalesce(v_seg,'null'));
    end if;

    /* ---- S5: VIP по сумме — временно снижаем vip_sum_min до 1000 ---- */
    update site_content set value = '1000' where key = 'segments.vip_sum_min';
    v_b := draft_clients_bundle();
    select s->>'segment' into v_seg from jsonb_array_elements(v_b->'stats') s
      where (s->>'client_id')::int = c_sum;
    if v_seg = 'vip' then
        insert into smoke_results (line) values ('PASS: S5 сумма >= порога — segment «vip» (по сумме, 2 заказа)');
    else
        insert into smoke_results (line) values ('FAIL: S5 segment=' || coalesce(v_seg,'null'));
    end if;
    update site_content set value = '100000' where key = 'segments.vip_sum_min';

    /* ---- S6: «уснул» — откат заказов на 91 день; кросс VIP + dormant ---- */
    update orders set created_at = now() - interval '91 days' where client_id = c_dor;
    update orders set created_at = now() - interval '91 days' where client_id = c_vip;
    v_b := draft_clients_bundle();
    select (s->>'is_dormant')::boolean, s->>'segment' into v_dor, v_seg
      from jsonb_array_elements(v_b->'stats') s where (s->>'client_id')::int = c_dor;
    if v_dor then
        insert into smoke_results (line) values ('PASS: S6 последний заказ 91 день назад — is_dormant true');
    else
        insert into smoke_results (line) values ('FAIL: S6 is_dormant=' || coalesce(v_dor::text,'null'));
    end if;
    select (s->>'is_dormant')::boolean, s->>'segment' into v_dor, v_seg
      from jsonb_array_elements(v_b->'stats') s where (s->>'client_id')::int = c_vip;
    if v_dor and v_seg = 'vip' then
        insert into smoke_results (line) values ('PASS: S6б кросс-фильтр — «уснувший VIP» (segment vip + is_dormant true)');
    else
        insert into smoke_results (line) values ('FAIL: S6б seg=' || coalesce(v_seg,'null') || ' dor=' || coalesce(v_dor::text,'null'));
    end if;

    /* ---- S7: крайний случай — клиент без заказов ---- */
    insert into clients (full_name, phone, phone_key)
    values ('Без Заказов', '+7 999 111-00-99', '79991110099')
    returning id into c_edge;
    v_b := draft_clients_bundle();
    if exists (select 1 from jsonb_array_elements(v_b->'clients') c
                where (c->>'id')::int = c_edge)
       and not exists (select 1 from jsonb_array_elements(v_b->'stats') s
                        where (s->>'client_id')::int = c_edge) then
        insert into smoke_results (line) values ('PASS: S7 клиент без заказов — в clients есть, в stats нет (фронт трактует как «new»/не уснул)');
    else
        insert into smoke_results (line) values ('FAIL: S7 клиент без заказов — неожиданный состав бандла');
    end if;

    /* ---- S8: мусор в порогах — fallback на дефолты, бандл не падает ---- */
    update site_content set value = 'abc' where key = 'segments.vip_orders_min';
    begin
        v_b := draft_clients_bundle();
        v_th := v_b->'thresholds';
        if (v_th->>'vip_orders_min')::int = 5 then
            insert into smoke_results (line) values ('PASS: S8 мусор в пороге — fallback на дефолт 5, бандл не падает');
        else
            insert into smoke_results (line) values ('FAIL: S8 thresholds=' || coalesce(v_th::text,'null'));
        end if;
    exception when others then
        insert into smoke_results (line) values ('FAIL: S8 бандл упал на мусоре: ' || sqlerrm);
    end;
    update site_content set value = '5' where key = 'segments.vip_orders_min';

    /* ---- S9: совместимость с формой v2 ---- */
    select s into v_st from jsonb_array_elements(v_b->'stats') s limit 1;
    if v_st ? 'orders' and v_st ? 'sum' and v_st ? 'paid_sum'
       and v_st ? 'first_order' and v_st ? 'last_order'
       and v_st ? 'segment' and v_st ? 'is_dormant'
       and (v_b->'thresholds') is not null
       and jsonb_array_length(v_b->'clients') >= 6 then
        insert into smoke_results (line) values ('PASS: S9 форма v2 сохранена + поля v3 (segment/is_dormant/thresholds)');
    else
        insert into smoke_results (line) values ('FAIL: S9 состав stats: ' || coalesce(v_st::text,'null'));
    end if;
end
$$;

select line from smoke_results order by n;
