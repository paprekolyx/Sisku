-- ============================================================================
--  SISKU (черновик) — СКРИПТ 26: лимиты текстовых полей заказа + часовые пояса
-- ============================================================================
--  Волна v0.17.0 (07.10.2026) — обработка внешнего ревью 06.10.2026:
--  (а) находка C3: create_order v8 — лимит длины свободных текстовых полей
--      (customer_name / customer_address / comment) — 1000 символов
--      (решение владельца 06.10.2026: «лимит текстовых полей для создания
--      в заказе — 1000 символов»); читаемые ошибки (P0001 → friendlyDbError);
--  (б) находка C1: check_promo v2 — границы ДАТ действия промокода
--      (valid_from/valid_until) трактуются в локальном времени магазина
--      Europe/Moscow вместо UTC current_date (решение владельца 06.10.2026:
--      «должно быть [везде] локальное время»). Относительные окна (анти-спам
--      3 заказа / 10 минут в create_order, окна промокодов) — интервалы,
--      от часового пояса не зависят, не меняются. РЕГЛАМЕНТ ВРЕМЕНИ:
--      моменты — timestamptz/UTC; календарные границы — Europe/Moscow;
--      фронтенд — локальная дата устройства (dayKey(), грабля №1);
--      порт в боевой MySQL 8 — CONVERT_TZ (migration-plan §5.1 п. 18).
--  Идемпотентен: create or replace function. Порядок: после baseline 01–09.
--  Применим и к живой базе (инкремент — модель F21).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. create_order v8 (база — v7, скрипт 19: защита подтверждённого имени)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_order(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_name      text;
    v_phone     text;
    v_email     text;
    v_address   text;
    v_comment   text;
    v_payment   integer;
    v_delivery  integer;
    v_items     jsonb;
    v_item      jsonb;
    v_qty       integer;
    v_line      record;
    v_lock      record;
    v_prod      record;
    v_total     numeric(10,2) := 0;
    v_net       numeric(10,2) := 0;
    v_deliv_cost numeric(10,2) := 0;
    v_order_id  integer;
    v_status_new integer;
    v_recent    integer;
    v_promo_code text;
    v_promo_id   integer;
    v_promo      record;
    v_discount   numeric(10,2) := 0;
    v_chk        jsonb;
    v_look_id    integer;
    v_look       public.looks%rowtype;
    v_look_item  record;
    v_look_sum   numeric(10,2) := 0;
    v_look_disc  numeric(10,2) := 0;
    v_in_cart    boolean;
    v_pkey       text;
    v_ekey       text;
    v_client_id  integer;
begin
    v_name    := nullif(btrim(coalesce(p->>'customer_name', '')), '');
    v_phone   := nullif(btrim(coalesce(p->>'customer_phone', '')), '');
    v_email   := nullif(lower(btrim(coalesce(p->>'customer_email', ''))), '');
    v_address := nullif(btrim(coalesce(p->>'customer_address', '')), '');
    v_comment := nullif(btrim(coalesce(p->>'comment', '')), '');

    /* v8 (волна v0.17.0, внешний ревью 06.10.2026 — находка C3): лимит длины
       свободных текстовых полей — 1000 символов (решение владельца
       06.10.2026); телефон и e-mail ограничены масками валидации, позиции —
       лимитом 50 штук выше по телу функции */
    if length(v_name) > 1000 then
        raise exception 'Слишком длинное имя (не более 1000 символов)';
    end if;
    if length(v_address) > 1000 then
        raise exception 'Слишком длинный адрес (не более 1000 символов)';
    end if;
    if length(v_comment) > 1000 then
        raise exception 'Слишком длинный комментарий (не более 1000 символов)';
    end if;
    v_payment := (p->>'payment_method_id')::integer;
    v_delivery:= (p->>'delivery_method_id')::integer;
    v_items   := coalesce(p->'items', '[]'::jsonb);
    v_promo_code := upper(btrim(coalesce(p->>'promo_code', '')));
    v_look_id := nullif(p->>'look_id', '')::integer;
    v_pkey    := public.draft_phone_key(v_phone);
    v_ekey    := public.draft_email_key(v_email);

    if v_name is null then
        raise exception 'Укажите имя';
    end if;
    if v_phone is null and v_email is null then
        raise exception 'Укажите телефон или e-mail для связи';
    end if;
    if jsonb_array_length(v_items) = 0 then
        raise exception 'Корзина пуста';
    end if;
    if jsonb_array_length(v_items) > 50 then
        raise exception 'Слишком много позиций в заказе (максимум 50)';
    end if;

    -- построчная валидация количества (до нормализации корзины)
    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_qty := coalesce((v_item->>'quantity')::integer, 0);
        if v_qty < 1 or v_qty > 99 then
            raise exception 'Некорректное количество товара';
        end if;
    end loop;

    -- анти-спам (fix F17): телефон сравнивается нормализованным ключом —
    -- «+7 999 123-45-67» и «89991234567» один и тот же человек
    select count(*) into v_recent
    from public.orders
    where created_at > now() - interval '10 minutes'
      and ((v_pkey is not null and public.draft_phone_key(customer_phone) = v_pkey)
        or (v_email is not null and lower(coalesce(customer_email, '')) = v_email));
    if v_recent >= 3 then
        raise exception 'Слишком много заказов подряд. Пожалуйста, попробуйте через несколько минут';
    end if;

    if not exists (select 1 from public.payment_methods where id = v_payment and is_active) then
        raise exception 'Некорректный способ оплаты';
    end if;
    select base_price into v_deliv_cost
    from public.delivery_methods
    where id = v_delivery and is_active;
    if v_deliv_cost is null then
        raise exception 'Некорректный способ доставки';
    end if;

    -- (fix F23) детерминированный порядок блокировок: товары по возрастанию id,
    -- затем варианты по возрастанию id. Параллельные заказы блокируют строки
    -- в одном порядке — deadlock 40P01 исключён.
    for v_lock in
        select distinct (x->>'product_id')::integer as pid
        from jsonb_array_elements(v_items) x
        where (x->>'product_id') is not null
        order by 1
    loop
        perform 1 from public.products where id = v_lock.pid for update;
    end loop;
    for v_lock in
        select distinct (x->>'variant_id')::integer as vid
        from jsonb_array_elements(v_items) x
        where (x->>'variant_id') is not null
        order by 1
    loop
        perform 1 from public.product_variants where id = v_lock.vid for update;
    end loop;

    -- (fix F08) нормализация корзины: строки одного варианта схлопываются
    -- в одну (qty суммируется) — дубль варианта больше не проходит поштучную
    -- валидацию против одного остатка
    for v_line in
        select (x->>'product_id')::integer as product_id,
               (x->>'variant_id')::integer as variant_id,
               sum(coalesce((x->>'quantity')::integer, 0)) as qty
        from jsonb_array_elements(v_items) x
        group by 1, 2
        order by 2
    loop
        select pr.id, pr.name, pr.price, pr.is_active, vr.label, vr.stock
        into v_prod
        from public.products pr
        join public.product_variants vr on vr.product_id = pr.id
        where pr.id = v_line.product_id
          and vr.id = v_line.variant_id;

        if v_prod.id is null or not v_prod.is_active then
            raise exception 'Товар недоступен для заказа';
        end if;
        if v_line.qty > 99 then
            raise exception 'Слишком много единиц одного товара в корзине (максимум 99)';
        end if;
        if v_prod.stock < v_line.qty then
            raise exception 'Недостаточно остатка: % (%), осталось % шт.', v_prod.name, v_prod.label, v_prod.stock;
        end if;

        v_total := v_total + v_prod.price * v_line.qty;
    end loop;

    -- комплект: скидка на сумму позиций лука, ФАКТИЧЕСКИ лежащих в корзине
    if v_look_id is not null then
        select * into v_look from public.looks where id = v_look_id and is_active;
        if v_look.id is null then
            raise exception 'Комплект не найден или отключён';
        end if;
        for v_look_item in
            select li.product_id, li.variant_id, pr.price
            from public.look_items li
            join public.products pr on pr.id = li.product_id
            where li.look_id = v_look_id
        loop
            select exists (
                select 1 from jsonb_array_elements(v_items) x
                where (x->>'product_id')::integer = v_look_item.product_id
                  and (
                       (v_look_item.variant_id is null and true)
                    or (x->>'variant_id')::integer = v_look_item.variant_id
                  )
            ) into v_in_cart;
            if v_in_cart then
                v_look_sum := v_look_sum + v_look_item.price;
            end if;
        end loop;
        v_look_disc := round(v_look_sum * v_look.discount_percent / 100, 2);
    end if;

    -- промокод: проверка и расчёт скидки только на сервере;
    -- (fix F03) строка кода блокируется, лимит перепроверяется под блокировкой
    if v_promo_code <> '' then
        v_chk := public.check_promo(v_promo_code, v_total);
        if coalesce((v_chk->>'ok')::boolean, false) then
            v_discount := (v_chk->>'discount_amount')::numeric(10,2);
            select pc.id, pc.usage_limit, pc.used_count
            into v_promo
            from public.promo_codes pc
            where pc.code = v_promo_code
            for update;
            if v_promo.id is null then
                raise exception 'Промокод не найден или отключён';
            end if;
            if v_promo.usage_limit is not null and v_promo.used_count >= v_promo.usage_limit then
                raise exception 'Лимит использований промокода исчерпан';
            end if;
            v_promo_id := v_promo.id;
        else
            raise exception '%', coalesce(v_chk->>'error', 'Промокод не применён');
        end if;
    end if;

    -- клиентская база (fix F02): UPSERT вместо select-then-insert —
    -- два параллельных заказа одного нового клиента не дают сырую ошибку 23505
    if v_pkey is not null then
        begin
            insert into public.clients (full_name, phone, email, address, phone_key, email_key)
            values (v_name, v_phone, v_email, v_address, v_pkey, v_ekey)
            on conflict (phone_key) do update
               set full_name  = case when public.clients.name_confirmed
                            then public.clients.full_name
                            else excluded.full_name end,   -- (v7, правка 2.20) подтверждённое имя не затирается
                   phone      = coalesce(excluded.phone, public.clients.phone),
                   email      = coalesce(excluded.email, public.clients.email),
                   address    = coalesce(excluded.address, public.clients.address),
                   email_key  = coalesce(public.clients.email_key, excluded.email_key),
                   updated_at = now()
            returning id into v_client_id;
        exception when unique_violation then
            -- e-mail уже занят другим клиентом при новом телефоне —
            -- объединяем с существующим клиентом по e-mail
            select id into v_client_id from public.clients where email_key = v_ekey limit 1;
            if v_client_id is null then
                raise exception 'Контактные данные конфликтуют с существующим клиентом — измените телефон или e-mail';
            end if;
            update public.clients
               set full_name  = case when name_confirmed then full_name
                            else v_name end,   -- (v7, правка 2.20)
                   phone      = coalesce(phone, v_phone),
                   address    = coalesce(address, v_address),
                   phone_key  = coalesce(phone_key, v_pkey),
                   updated_at = now()
             where id = v_client_id;
        end;
    elsif v_ekey is not null then
        begin
            insert into public.clients (full_name, phone, email, address, phone_key, email_key)
            values (v_name, v_phone, v_email, v_address, v_pkey, v_ekey)
            on conflict (email_key) do update
               set full_name  = case when public.clients.name_confirmed
                            then public.clients.full_name
                            else excluded.full_name end,   -- (v7, правка 2.20) подтверждённое имя не затирается
                   phone      = coalesce(excluded.phone, public.clients.phone),
                   address    = coalesce(excluded.address, public.clients.address),
                   phone_key  = coalesce(public.clients.phone_key, excluded.phone_key),
                   updated_at = now()
            returning id into v_client_id;
        exception when unique_violation then
            select id into v_client_id from public.clients where email_key = v_ekey limit 1;
            if v_client_id is null then
                raise exception 'Контактные данные конфликтуют с существующим клиентом — измените телефон или e-mail';
            end if;
            update public.clients
               set full_name  = case when name_confirmed then full_name
                            else v_name end,   -- (v7, правка 2.20)
                   phone      = coalesce(phone, v_phone),
                   address    = coalesce(address, v_address),
                   updated_at = now()
             where id = v_client_id;
        end;
    else
        insert into public.clients (full_name, phone, email, address)
        values (v_name, v_phone, v_email, v_address)
        returning id into v_client_id;
    end if;

    select id into v_status_new from public.order_statuses where code = 'new';

    -- (fix F07) итог не может быть отрицательным: скидки, стекающиеся
    -- сверх суммы товаров (fixed-промо + комплект), обрезаются нулём
    v_net := greatest(v_total - v_discount - v_look_disc, 0);

    insert into public.orders (
        customer_name, customer_phone, customer_email, customer_address,
        status_id, payment_method_id, delivery_method_id,
        total, delivery_cost, comment, promo_code_id, look_id,
        client_id, promo_discount, look_discount
    ) values (
        v_name, v_phone, v_email, v_address,
        v_status_new, v_payment, v_delivery,
        v_net, v_deliv_cost, v_comment, v_promo_id, v_look_id,
        v_client_id, v_discount, v_look_disc
    ) returning id into v_order_id;

    -- позиции: одна строка на вариант (итог нормализации корзины);
    -- (fix F12) join снова содержит vr.product_id = pr.id
    for v_line in
        select (x->>'product_id')::integer as product_id,
               (x->>'variant_id')::integer as variant_id,
               sum(coalesce((x->>'quantity')::integer, 0)) as qty
        from jsonb_array_elements(v_items) x
        group by 1, 2
        order by 2
    loop
        insert into public.order_items (
            order_id, product_id, variant_id, quantity, price, title_snapshot, variant_snapshot
        )
        select v_order_id, pr.id, vr.id, v_line.qty, pr.price, pr.name, vr.label
        from public.products pr
        join public.product_variants vr on vr.product_id = pr.id
        where pr.id = v_line.product_id
          and vr.id = v_line.variant_id;

        -- (fix F08) условное списание: защита от перепродажи даже если
        -- валидация выше когда-нибудь разойдётся с фактом
        update public.product_variants
           set stock = stock - v_line.qty
         where id = v_line.variant_id
           and stock >= v_line.qty;
        if not found then
            raise exception 'Недостаточно остатка на складе — обновите корзину и попробуйте снова';
        end if;
    end loop;

    -- (fix F03) условный инкремент: второй страховкой лимит не пробивается
    if v_promo_id is not null then
        update public.promo_codes
           set used_count = used_count + 1
         where id = v_promo_id
           and (usage_limit is null or used_count < usage_limit);
        if not found then
            raise exception 'Лимит использований промокода исчерпан';
        end if;
    end if;

    insert into public.deliveries (order_id, delivery_method_id, address, cost)
    select v_order_id, v_delivery, v_address, v_deliv_cost;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (v_order_id, v_status_new, 'system', 'Заказ создан на сайте');

    return jsonb_build_object(
        'order_id', v_order_id,
        'client_id', v_client_id,
        'total', v_net,
        'discount', v_discount,
        'look_discount', v_look_disc,
        'delivery_cost', v_deliv_cost,
        'grand_total', v_net + v_deliv_cost);
end;
$$;

comment on function public.create_order(jsonb) is 'v8 (волна v0.17.0, внешний ревью 06.10.2026 — C3): лимит длины текстовых полей заказа ≤1000 символов; база — v7 (волна v0.15.0, скрипт 19): подтверждённое имя не перезаписывается';

-- ----------------------------------------------------------------------------
-- 2. check_promo v2 (границы дат — Europe/Moscow)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_promo(p_code text, p_total numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_promo   public.promo_codes%rowtype;
    v_amount  numeric(10,2);
begin
    select * into v_promo
    from public.promo_codes
    where code = upper(btrim(coalesce(p_code, '')))
    limit 1;

    if v_promo.id is null or not v_promo.is_active then
        return jsonb_build_object('ok', false, 'error', 'Промокод не найден или отключён');
    end if;
    if v_promo.valid_from is not null and (now() at time zone 'Europe/Moscow')::date < v_promo.valid_from then
        return jsonb_build_object('ok', false, 'error', 'Промокод ещё не действует');
    end if;
    if v_promo.valid_until is not null and (now() at time zone 'Europe/Moscow')::date > v_promo.valid_until then
        return jsonb_build_object('ok', false, 'error', 'Срок действия промокода истёк');
    end if;
    if v_promo.usage_limit is not null and v_promo.used_count >= v_promo.usage_limit then
        return jsonb_build_object('ok', false, 'error', 'Лимит использований исчерпан');
    end if;
    if p_total < coalesce(v_promo.min_order_amount, 0) then
        return jsonb_build_object('ok', false, 'error',
            'Промокод действует от ' || v_promo.min_order_amount || ' ₽');
    end if;

    if v_promo.discount_type = 'percent' then
        v_amount := round(p_total * v_promo.discount_value / 100, 2);
    else
        v_amount := least(v_promo.discount_value, p_total);
    end if;

    return jsonb_build_object(
        'ok', true,
        'code', v_promo.code,
        'discount_type', v_promo.discount_type,
        'discount_value', v_promo.discount_value,
        'discount_amount', v_amount);
end;
$$;

comment on function public.check_promo(text, numeric) is 'v2 (волна v0.17.0, внешний ревью 06.10.2026 — C1): границы дат действия промокода — в локальном времени магазина Europe/Moscow (решение владельца 06.10.2026)';

-- ----------------------------------------------------------------------------
-- 3. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select (length(pg_get_functiondef(p.oid))
             - length(replace(pg_get_functiondef(p.oid),
                              'не более 1000 символов', '')))
            / length('не более 1000 символов')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'create_order')   as limit_msgs,        -- ждём 3
    (select pg_get_functiondef(p.oid) like '%length(v_comment) > 1000%'
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'create_order')   as create_order_v8,   -- ждём t
    (select (length(p.prosrc) - length(replace(p.prosrc,
                        'Europe/Moscow', ''))) / length('Europe/Moscow')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'check_promo')    as tz_occurrences,    -- ждём 2
    (select p.prosrc not like '%current_date%'
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'check_promo')    as utc_date_gone,     -- ждём t
    (select prosrc like '%name_confirmed%' from pg_proc
      where proname = 'create_order')                              as v7_base_kept;      -- ждём t (логика v7 не потеряна)
