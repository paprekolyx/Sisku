-- ============================================================================
--  SISKU (черновик) — СКРИПТ 03: функции ядра записи — 20 конечных версий (консолидация v0.21.1)
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE, ревизия 2 (волна v0.21.1, 17.10.2026):
--  состояние базы на v0.21.0 шестью скриптами (первая ревизия — v0.17.0,
--  состояние на v0.16.0; инкременты 26–33 поглощены — замороженный архив
--  supabase/archive/sql-26-33-v0210.md). Baseline ЗАМОРОЖЕН (правило 9):
--  правки — только новыми инкрементами с номера 34.
--  Живая база НЕ перезапускается (модель F21): baseline — только для
--  новых стендов; живая база получает инкременты ≥ 34.
--  Идемпотентен: create if not exists / drop-create policy / on conflict
--  do nothing / create or replace. Порядок: 01 → 02 → 03 → 04 → 05 → 09.
-- ============================================================================

-- Функции сгенерированы из конечного состояния каталога эталонной базы
-- (create or replace; порядок — ядро заказа → возвраты → клиенты →
--  инвентаризация/списания → бейджи)

-- ---------- draft_phone_key ----------
CREATE OR REPLACE FUNCTION public.draft_phone_key(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $$
    select case
             when x.digits is null then null
             when length(x.digits) = 11 and left(x.digits, 1) = '8'
                 then '7' || substr(x.digits, 2)
             else x.digits
           end
    from (select nullif(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '')) as x(digits);
$$;

comment on function public.draft_phone_key is 'Нормализованный телефон для дедупликации: только цифры, ведущая 8 заменяется на 7';

-- ---------- draft_email_key ----------
CREATE OR REPLACE FUNCTION public.draft_email_key(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $$
    select nullif(lower(btrim(coalesce(p, ''))), '');
$$;

comment on function public.draft_email_key is 'Нормализованный e-mail для дедупликации: trim + нижний регистр';

-- ---------- check_promo ----------
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

comment on function public.check_promo is 'v2 (волна v0.17.0, внешний ревью 06.10.2026 — C1): границы дат действия промокода — в локальном времени магазина Europe/Moscow (решение владельца 06.10.2026)';

-- ---------- create_order ----------
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
    v_client_new boolean := false;   /* v9: клиент создан этим заказом */
    v_cur_phone  text;                /* v9: текущие контакты — для истории */
    v_cur_email  text;
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
                   address    = coalesce(excluded.address, public.clients.address),
                   updated_at = now()
                   /* v9 (Д3): пары (phone, phone_key) и (email, email_key) НЕ
                      перезаписываются — отличный от текущего контакт заказа
                      уходит в client_contact_history ('offered') ниже по телу */
            returning id, (xmax = 0) into v_client_id, v_client_new;
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
                   address    = coalesce(address, v_address),
                   /* v9 (Д2а/Д3): телефон принимается, только если у клиента
                      его ещё нет и ключ свободен — иначе контакт уходит
                      в историю ('offered'); сырая 23505 исключена */
                   phone      = case when phone is null
                                      and not exists (select 1 from public.clients c2
                                                      where c2.phone_key = v_pkey)
                                     then v_phone else phone end,
                   phone_key  = case when phone_key is null
                                      and not exists (select 1 from public.clients c2
                                                      where c2.phone_key = v_pkey)
                                     then v_pkey else phone_key end,
                   updated_at = now()
             where id = v_client_id;
        end;
    elsif v_ekey is not null then
        /* v9: в этой ветке v_pkey заведомо null — phone_key уникальность
           нарушить не может; мёртвый exception-блок v8 убран; пары контактов
           не перезаписываются (Д3) — отличный телефон заказа уходит в историю */
        insert into public.clients (full_name, phone, email, address, phone_key, email_key)
        values (v_name, v_phone, v_email, v_address, v_pkey, v_ekey)
        on conflict (email_key) do update
           set full_name  = case when public.clients.name_confirmed
                        then public.clients.full_name
                        else excluded.full_name end,   -- (v7, правка 2.20) подтверждённое имя не затирается
               address    = coalesce(excluded.address, public.clients.address),
               updated_at = now()
        returning id, (xmax = 0) into v_client_id, v_client_new;
    else
        insert into public.clients (full_name, phone, email, address)
        values (v_name, v_phone, v_email, v_address)
        returning id, true into v_client_id, v_client_new;
    end if;

    /* ----------------------------------------------------------------------
       v9 (волна v0.18.0, правила владельца 05.10.2026, решения Д1–Д3):
       история вариантов имён и контактов. Вариант имени пишется КАЖДЫМ
       заказом (включая подтверждённое имя — перезаписи full_name при этом
       нет, логика v7 сохранена); контакты — только события: новый клиент
       ('set'), отличный от текущего контакт существующего клиента
       ('offered' — не принят, пары ключей не перезаписываются).
       ---------------------------------------------------------------------- */
    insert into public.client_name_history (client_id, full_name, source, created_by)
    values (v_client_id, v_name, 'order', 'site');

    select c.phone, c.email into v_cur_phone, v_cur_email
    from public.clients c where c.id = v_client_id;

    if v_client_new then
        if v_phone is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_client_id, 'phone', v_phone, 'set', 'site');
        end if;
        if v_email is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_client_id, 'email', v_email, 'set', 'site');
        end if;
    else
        if v_phone is not null
           and public.draft_phone_key(v_cur_phone) is distinct from v_pkey then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_client_id, 'phone', v_phone, 'offered', 'site');
        end if;
        if v_email is not null
           and public.draft_email_key(v_cur_email) is distinct from v_ekey then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_client_id, 'email', v_email, 'offered', 'site');
        end if;
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

comment on function public.create_order is 'v9 (волна v0.18.0, правила владельца 05.10.2026, решения Д2а/Д3): варианты имени — в client_name_history; пары контактов при слиянии не перезаписываются (отличный контакт заказа — в client_contact_history «offered»); слияние — только по e-mail; заказ на старые контакты — новый клиент; база — v8 (волна v0.17.0, скрипт 26): лимит текстовых полей ≤1000 символов';

-- ---------- admin_set_status ----------
CREATE OR REPLACE FUNCTION public.admin_set_status(p_order_id integer, p_status_code text, p_comment text DEFAULT NULL::text, p_changed_by text DEFAULT 'admin'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_from integer;
    v_to   integer;
    v_from_name text;
    v_to_name   text;
    v_item      record;
begin
    -- v3 (fix F01): FOR UPDATE — параллельные вызовы для одного заказа
    -- выстраиваются в очередь; второй вызов увидит уже новый статус
    -- и не вернёт остатки повторно.
    select status_id into v_from
    from public.orders
    where id = p_order_id
    for update;
    if v_from is null then
        raise exception 'Заказ не найден';
    end if;
    select id, name into v_to, v_to_name from public.order_statuses where code = p_status_code;
    if v_to is null then
        raise exception 'Неизвестный статус: %', p_status_code;
    end if;
    if v_to = v_from then
        return jsonb_build_object('ok', true, 'status', p_status_code, 'note', 'без изменения');
    end if;

    if not exists (
        select 1 from public.status_transitions
        where from_status_id = v_from and to_status_id = v_to
    ) then
        select name into v_from_name from public.order_statuses where id = v_from;
        raise exception 'Переход запрещён моделью: % → %', v_from_name, v_to_name;
    end if;

    update public.orders set status_id = v_to where id = p_order_id;

    -- v4 (волна v0.16.0, фикс F51): возврат остатков РАЗДЕЛЁН —
    -- «Отменён» — в продажу (stock), как раньше; «Возврат» — в КАРАНТИН
    -- (quarantine_qty, требует осмотра; решение аналитика 06.10.2026 —
    -- схема (а) счётчик; движения — fp №3b).
    if p_status_code = 'cancelled' then
        for v_item in
            select variant_id, quantity from public.order_items
            where order_id = p_order_id and variant_id is not null
        loop
            update public.product_variants
               set stock = stock + v_item.quantity
             where id = v_item.variant_id;
        end loop;
    elsif p_status_code = 'returned' then
        for v_item in
            select variant_id, quantity from public.order_items
            where order_id = p_order_id and variant_id is not null
        loop
            update public.product_variants
               set quarantine_qty = quarantine_qty + v_item.quantity
             where id = v_item.variant_id;
        end loop;
    end if;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (p_order_id, v_to, p_changed_by, p_comment);

    return jsonb_build_object('ok', true, 'status', p_status_code, 'status_name', v_to_name);
end;
$$;

comment on function public.admin_set_status is 'v4 (волна v0.16.0, фикс F51): смена статуса с проверкой status_transitions и FOR UPDATE (fix F01); «Отменён» — остатки в stock, «Возврат» — в карантин quarantine_qty (требует осмотра, admin_resolve_quarantine)';

-- ---------- admin_set_paid ----------
CREATE OR REPLACE FUNCTION public.admin_set_paid(p_order_id integer, p_is_paid boolean, p_changed_by text DEFAULT 'admin'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_status_id integer;
    v_was_paid  boolean;
begin
    select status_id, is_paid into v_status_id, v_was_paid
    from public.orders
    where id = p_order_id
    for update;

    if v_status_id is null then
        raise exception 'Заказ не найден';
    end if;

    update public.orders
       set is_paid = p_is_paid,
           paid_at = case when p_is_paid then coalesce(paid_at, now()) else null end
     where id = p_order_id;

    -- событие оплаты — в историю заказа (только при фактическом изменении);
    -- статус в строке истории остаётся текущим: это не статусный переход
    if v_was_paid is distinct from p_is_paid then
        insert into public.order_status_history (order_id, status_id, changed_by, comment)
        values (
            p_order_id,
            v_status_id,
            coalesce(nullif(btrim(p_changed_by), ''), 'admin'),
            case when p_is_paid
                 then 'Оплата: заказ отмечен оплаченным'
                 else 'Оплата: отметка об оплате снята'
            end
        );
    end if;

    return jsonb_build_object('ok', true, 'is_paid', p_is_paid);
end;
$$;

comment on function public.admin_set_paid is 'v2 (скрипт 18, волна v0.15.0, правка 2.2): признак оплаты можно менять у заказа в любом статусе, включая отменённый (деньги могли поступить или быть возвращены); статусные переходы по-прежнему только через admin_set_status; событие смены оплаты пишется в историю заказа с автором';

-- ---------- track_order ----------
CREATE OR REPLACE FUNCTION public.track_order(p_order_id integer, p_tail text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_order    public.orders%rowtype;
    v_code     text;
    v_name     text;
    v_tail     text;
    v_phone4   text;
    v_mail4    text;
    v_history  jsonb;
begin
    v_tail := lower(btrim(coalesce(p_tail, '')));
    select * into v_order from public.orders where id = p_order_id;
    if v_order.id is null or v_tail = '' then
        return jsonb_build_object('found', false);
    end if;

    v_phone4 := right(regexp_replace(coalesce(v_order.customer_phone, ''), '\D', '', 'g'), 4);
    v_mail4  := left(split_part(lower(coalesce(v_order.customer_email, '')), '@', 1), 4);

    if v_tail <> v_phone4 and v_tail <> v_mail4 then
        return jsonb_build_object('found', false);
    end if;

    select s.code, s.name into v_code, v_name
    from public.order_statuses s where s.id = v_order.status_id;

    select coalesce(jsonb_agg(jsonb_build_object(
        'status', s.name,
        'changed_at', h.changed_at,
        'comment', h.comment) order by h.changed_at), '[]'::jsonb)
    into v_history
    from public.order_status_history h
    join public.order_statuses s on s.id = h.status_id
    where h.order_id = v_order.id;

    -- v2 (волна v0.16.0): добавлены status_code/status_name/return_available;
    -- состав v1 сохранён (обратная совместимость витрины)
    return jsonb_build_object(
        'found', true,
        'created_at', v_order.created_at,
        'total', v_order.total + v_order.delivery_cost,
        'history', v_history,
        'status_code', v_code,
        'status_name', v_name,
        'return_available', v_code in ('shipped', 'delivered'));
end;
$$;

comment on function public.track_order is 'v2 (волна v0.16.0): отслеживание заказа покупателем + status_code/status_name/return_available — форма «Оформить возврат» доступна из статусов «Отправлен» и «Доставлен»';

-- ---------- draft_save_look ----------
CREATE OR REPLACE FUNCTION public.draft_save_look(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_id      integer;
    v_title   text;
    v_disc    numeric(5,2);
    v_item    jsonb;
    v_pid     integer;
    v_vid     integer;
    v_sort    integer := 0;
    v_items   jsonb;
begin
    v_id    := nullif(btrim(coalesce(p->>'id', '')), '')::integer;
    v_title := nullif(btrim(coalesce(p->>'title', '')), '');
    v_disc  := coalesce((p->>'discount_percent')::numeric(5,2), 0);
    v_items := coalesce(p->'items', '[]'::jsonb);

    -- валидация (зеркалит клиентскую в looks.js — сервер истина)
    if v_title is null or length(v_title) < 3 then
        raise exception 'Укажите название комплекта (минимум 3 символа)';
    end if;
    if v_disc < 0 or v_disc > 90 then
        raise exception 'Скидка комплекта: от 0 до 90 процентов';
    end if;
    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
        raise exception 'Добавьте в комплект хотя бы один товар';
    end if;
    if jsonb_array_length(v_items) > 50 then
        raise exception 'Слишком много позиций в комплекте (максимум 50)';
    end if;

    -- состав проверяется ДО записи: товар существует, вариант принадлежит товару
    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_pid := nullif(btrim(coalesce(v_item->>'product_id', '')), '')::integer;
        v_vid := nullif(btrim(coalesce(v_item->>'variant_id', '')), '')::integer;
        if v_pid is null or not exists (select 1 from public.products where id = v_pid) then
            raise exception 'Товар позиции % не найден в каталоге — обновите список товаров', coalesce(v_pid::text, '?');
        end if;
        if v_vid is not null and not exists (
            select 1 from public.product_variants
            where id = v_vid and product_id = v_pid
        ) then
            raise exception 'Вариант позиции % не принадлежит выбранному товару — обновите список вариантов', v_pid::text;
        end if;
    end loop;

    -- комплект: создание или обновление
    if v_id is null then
        insert into public.looks (title, description, discount_percent, is_active)
        values (
            v_title,
            nullif(btrim(coalesce(p->>'description', '')), ''),
            v_disc,
            coalesce((p->>'is_active')::boolean, true)
        )
        returning id into v_id;
    else
        update public.looks
           set title            = v_title,
               description      = nullif(btrim(coalesce(p->>'description', '')), ''),
               discount_percent = v_disc,
               is_active        = coalesce((p->>'is_active')::boolean, true)
         where id = v_id;
        if not found then
            raise exception 'Комплект № % не найден — обновите список', v_id;
        end if;
        -- состав заменяется целиком (как раньше в looks.js, но в той же транзакции)
        delete from public.look_items where look_id = v_id;
    end if;

    -- позиции — в порядке строк редактора
    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_sort := v_sort + 1;
        insert into public.look_items (look_id, product_id, variant_id, sort_order)
        values (
            v_id,
            nullif(btrim(coalesce(v_item->>'product_id', '')), '')::integer,
            nullif(btrim(coalesce(v_item->>'variant_id', '')), '')::integer,
            v_sort
        );
    end loop;

    return jsonb_build_object('ok', true, 'look_id', v_id, 'items', v_sort);
end;
$$;

comment on function public.draft_save_look is 'v1 (скрипт 17, волна v0.15.0, правка 2.1-Б): сохранение комплекта и состава одной транзакцией — комплект больше не может остаться без позиций; серверная валидация названия, скидки и состава';

-- ---------- create_return_request ----------
CREATE OR REPLACE FUNCTION public.create_return_request(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_order_id  integer;
    v_tail      text;
    v_reason_id integer;
    v_comment   text;
    v_order     record;
    v_phone4    text;
    v_mail4     text;
    v_open      integer;
    v_recent    integer;
    v_id        integer;
begin
    v_order_id  := nullif(btrim(coalesce(p->>'order_id', '')), '')::integer;
    v_tail      := lower(btrim(coalesce(p->>'code', '')));
    v_reason_id := nullif(btrim(coalesce(p->>'reason_id', '')), '')::integer;
    v_comment   := nullif(btrim(coalesce(p->>'comment', '')), '');

    if v_order_id is null or v_tail = '' then
        raise exception 'Укажите номер заказа и код подтверждения';
    end if;
    if v_reason_id is null then
        raise exception 'Укажите причину возврата';
    end if;
    if v_comment is not null and length(v_comment) > 2000 then
        raise exception 'Комментарий слишком длинный (до 2000 символов)';
    end if;

    -- заказ существует + статус, из которого принимается заявка
    select o.id, s.code as status_code, o.customer_phone, o.customer_email
    into v_order
    from public.orders o
    join public.order_statuses s on s.id = o.status_id
    where o.id = v_order_id;
    if v_order.id is null then
        raise exception 'Заказ не найден';
    end if;
    if v_order.status_code not in ('shipped', 'delivered') then
        raise exception 'Заявка на возврат доступна для заказов в статусе «Отправлен» или «Доставлен»';
    end if;

    -- код подтверждения — механизм track_order (скрипт 10)
    v_phone4 := right(regexp_replace(coalesce(v_order.customer_phone, ''), '\D', '', 'g'), 4);
    v_mail4  := left(split_part(lower(coalesce(v_order.customer_email, '')), '@', 1), 4);
    if v_tail <> v_phone4 and v_tail <> v_mail4 then
        raise exception 'Заказ не найден или код подтверждения не совпадает';
    end if;

    -- причина — только активная из справочника
    if not exists (select 1 from public.return_reasons where id = v_reason_id and is_active) then
        raise exception 'Выберите причину возврата из списка';
    end if;

    -- антиспам: одна незакрытая заявка на заказ (повторные не делаем —
    -- решение аналитика 06.10.2026) + лимит 3 заявки за 10 минут на заказ
    select count(*) into v_open
    from public.return_requests
    where order_id = v_order_id
      and status in ('created', 'returned_to_stock', 'verified');
    if v_open > 0 then
        raise exception 'Заявка на возврат этого заказа уже оформлена и находится в обработке';
    end if;
    select count(*) into v_recent
    from public.return_requests
    where order_id = v_order_id
      and created_at > now() - interval '10 minutes';
    if v_recent >= 3 then
        raise exception 'Слишком много заявок подряд. Пожалуйста, попробуйте через несколько минут';
    end if;

    insert into public.return_requests (order_id, reason_id, comment, created_by)
    values (v_order_id, v_reason_id, v_comment, 'site')
    returning id into v_id;

    return jsonb_build_object('ok', true, 'request_id', v_id);
end;
$$;

comment on function public.create_return_request is 'Заявка на возврат покупателем: номер заказа + код подтверждения (механизм track_order), заказ в статусе shipped/delivered, причина активная, антиспам — одна незакрытая заявка на заказ и 3/10 мин';

-- ---------- admin_set_return_status ----------
CREATE OR REPLACE FUNCTION public.admin_set_return_status(p_request_id integer, p_status_code text, p_comment text DEFAULT NULL::text, p_changed_by text DEFAULT 'admin'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_req    record;
    v_author text;
begin
    select * into v_req from public.return_requests where id = p_request_id for update;
    if v_req.id is null then
        raise exception 'Заявка не найдена';
    end if;
    if p_status_code not in ('created', 'returned_to_stock', 'verified', 'rejected') then
        raise exception 'Неизвестный статус заявки: %', p_status_code;
    end if;
    if v_req.status = p_status_code then
        return jsonb_build_object('ok', true, 'status', p_status_code, 'note', 'без изменения');
    end if;

    -- модель переходов заявки
    if not (
        (v_req.status = 'created'          and p_status_code in ('returned_to_stock', 'rejected')) or
        (v_req.status = 'returned_to_stock' and p_status_code in ('verified', 'rejected'))
    ) then
        raise exception 'Переход запрещён моделью: % → %', v_req.status, p_status_code;
    end if;

    v_author := coalesce(nullif(btrim(p_changed_by), ''), 'admin');

    -- «Товар вернулся на склад»: заказ переводится в «Возврат» той же
    -- функцией, что и кнопка в карточке заказа (admin_set_status). С волны
    -- v0.16.0 (скрипт 23, admin_set_status v4) остатки при «Возврате» уходят
    -- в КАРАНТИН (quarantine_qty), а не в продажу. Вызов идемпотентен:
    -- если заказ уже «Возврат» — admin_set_status вернёт «без изменения».
    if p_status_code = 'returned_to_stock' then
        perform public.admin_set_status(
            v_req.order_id, 'returned',
            trim(both ' ' from 'Возврат по заявке № ' || v_req.id ||
                 coalesce('. ' || nullif(btrim(p_comment), ''), '.')),
            v_author
        );
    end if;

    update public.return_requests
       set status      = p_status_code,
           handled_by  = v_author,
           resolved_at = case when p_status_code in ('verified', 'rejected')
                              then coalesce(resolved_at, now()) else null end
     where id = p_request_id;

    return jsonb_build_object('ok', true, 'status', p_status_code);
end;
$$;

comment on function public.admin_set_return_status is 'Переходы статуса заявки: created → returned_to_stock → verified / rejected (created → rejected). При returned_to_stock заказ переводится в «Возврат» (admin_set_status; с скрипта 23 — остатки в карантин). verified/rejected — финальные, пишется resolved_at';

-- ---------- admin_set_return_refund ----------
CREATE OR REPLACE FUNCTION public.admin_set_return_refund(p_request_id integer, p_paid boolean, p_receipt text DEFAULT NULL::text, p_changed_by text DEFAULT 'admin'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_req record;
begin
    select * into v_req from public.return_requests where id = p_request_id for update;
    if v_req.id is null then
        raise exception 'Заявка не найдена';
    end if;

    update public.return_requests
       set refund_paid    = p_paid,
           refund_paid_at = case when p_paid then coalesce(refund_paid_at, now()) else null end,
           refund_receipt = nullif(btrim(coalesce(p_receipt, '')), ''),
           handled_by     = coalesce(nullif(btrim(p_changed_by), ''), 'admin')
     where id = p_request_id;

    return jsonb_build_object('ok', true, 'refund_paid', p_paid);
end;
$$;

comment on function public.admin_set_return_refund is 'Флаг «Деньги возвращены» + дата + реквизиты чека возврата (в макете необязательные — 54-ФЗ в боевом контуре M4)';

-- ---------- admin_resolve_quarantine ----------
CREATE OR REPLACE FUNCTION public.admin_resolve_quarantine(p_variant_id integer, p_qty integer, p_action text, p_changed_by text DEFAULT 'admin'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_var record;
begin
    select * into v_var from public.product_variants where id = p_variant_id for update;
    if v_var.id is null then
        raise exception 'Вариант товара не найден';
    end if;
    if p_qty is null or p_qty < 1 then
        raise exception 'Укажите количество (не меньше 1)';
    end if;
    if p_qty > v_var.quarantine_qty then
        raise exception 'В карантине только % шт. этого варианта', v_var.quarantine_qty;
    end if;
    if p_action not in ('restock', 'writeoff') then
        raise exception 'Неизвестное действие осмотра: %', p_action;
    end if;

    if p_action = 'restock' then
        update public.product_variants
           set quarantine_qty = quarantine_qty - p_qty,
               stock          = stock + p_qty
         where id = p_variant_id;
    else
        update public.product_variants
           set quarantine_qty = quarantine_qty - p_qty
         where id = p_variant_id;
    end if;

    select stock, quarantine_qty into v_var from public.product_variants where id = p_variant_id;

    return jsonb_build_object(
        'ok', true, 'variant_id', p_variant_id, 'action', p_action, 'qty', p_qty,
        'stock', v_var.stock, 'quarantine_qty', v_var.quarantine_qty,
        'changed_by', coalesce(nullif(btrim(p_changed_by), ''), 'admin'));
end;
$$;

comment on function public.admin_resolve_quarantine is 'Осмотр карантина (волна v0.16.0): restock — вернуть в продажу (карантин → stock), writeoff — списать (убрать из карантина без возврата в stock); FOR UPDATE на варианте, qty ≤ quarantine_qty; журнал движений — fp №3b (v0.28.0)';

-- ---------- admin_update_client ----------
CREATE OR REPLACE FUNCTION public.admin_update_client(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_id     integer;
    v_name   text;
    v_phone  text;
    v_email  text;
    v_note   text;
    v_pkey   text;
    v_ekey   text;
    v_old    record;
begin
    v_id    := nullif(btrim(coalesce(p->>'client_id', '')), '')::integer;
    v_name  := nullif(btrim(coalesce(p->>'full_name', '')), '');
    v_phone := nullif(btrim(coalesce(p->>'phone', '')), '');
    v_email := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
    v_note  := nullif(btrim(coalesce(p->>'note', '')), '');

    if v_id is null then
        raise exception 'Клиент не указан';
    end if;
    if v_name is null then
        raise exception 'ФИО не может быть пустым';
    end if;
    if length(v_name) > 1000 then
        raise exception 'Слишком длинное имя (не более 1000 символов)';
    end if;
    if length(coalesce(v_note, '')) > 2000 then
        raise exception 'Слишком длинный комментарий (не более 2000 символов)';
    end if;
    if v_phone is null and v_email is null then
        raise exception 'Оставьте хотя бы один контакт: телефон или e-mail';
    end if;

    /* серверное зеркало масок util.js (phoneOk/emailOk): телефон — 11 цифр
       с ведущей 7 после нормализации (8→7), почта — простая маска a@b.cc */
    v_pkey := public.draft_phone_key(v_phone);
    /* draft_phone_key возвращает только цифры (8→7) — регэксы не нужны:
       валидность = 11 цифр с ведущей 7 (без dollar-якоря — регламент
       «одиночных долларов нет», правило 4 supabase/README) */
    if v_phone is not null
       and (v_pkey is null or length(v_pkey) <> 11 or left(v_pkey, 1) <> '7') then
        raise exception 'Формат телефона: +7 (999) 123-45-67 или 8 999 123-45-67';
    end if;
    v_ekey := public.draft_email_key(v_email);
    if v_email is not null
       and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}\Z' then
        raise exception 'Формат почты: name@example.ru';
    end if;

    select c.id, c.full_name, c.phone, c.email
      into v_old
      from public.clients c
     where c.id = v_id
     for update;
    if v_old.id is null then
        raise exception 'Клиент не найден';
    end if;

    begin
        update public.clients
           set full_name      = v_name,
               phone          = v_phone,
               email          = v_email,
               note           = v_note,
               phone_key      = v_pkey,
               email_key      = v_ekey,
               name_confirmed = true,   /* правка 2.20 (v0.15.0): сохранение
                                          карточки = имя подтверждено */
               updated_at     = now()
         where id = v_id;
    exception when unique_violation then
        raise exception 'Такой телефон или e-mail уже принадлежит другому клиенту — объедините дубли вручную (Table Editor → clients).';
    end;

    /* история контактов (правило владельца 05.10.2026: вести так же, как
       историю имён): старое значение — 'invalidated', новое — 'changed' */
    if coalesce(v_old.phone, '') <> coalesce(v_phone, '') then
        if v_old.phone is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_id, 'phone', v_old.phone, 'invalidated', 'admin');
        end if;
        if v_phone is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_id, 'phone', v_phone, 'changed', 'admin');
        end if;
    end if;
    if coalesce(v_old.email, '') <> coalesce(v_email, '') then
        if v_old.email is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_id, 'email', v_old.email, 'invalidated', 'admin');
        end if;
        if v_email is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_id, 'email', v_email, 'changed', 'admin');
        end if;
    end if;
    if v_old.full_name <> v_name then
        insert into public.client_name_history (client_id, full_name, source, created_by)
        values (v_id, v_name, 'admin', 'admin');
    end if;

    return jsonb_build_object('ok', true, 'client_id', v_id);
end;
$$;

comment on function public.admin_update_client is 'v1 (волна v0.18.0, решение Д4): сохранение карточки клиента одной транзакцией — clients (включая ключи дедупликации и name_confirmed) + client_contact_history (старое — invalidated, новое — changed) + client_name_history (admin); серверная валидация форматов — зеркало масок util.js; 23505 — читаемое сообщение';

-- ---------- admin_create_inventory_session ----------
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

comment on function public.admin_create_inventory_session is 'Создание сессии инвентаризации (волна v0.20.0, fp №9, Д2/Д3): p = {scope: all|categories, category_ids?, plan_date?, participant_ids?, created_by?}; статус planned (переходы только ручные — авто-старта по план-дате нет); лист заполняется snapshot-ом активных вариантов области (stock + резерв открытых заказов + карантин = «ожидаемо физически») одной вставкой';

-- ---------- admin_start_inventory_session ----------
CREATE OR REPLACE FUNCTION public.admin_start_inventory_session(p_session_id integer, p_changed_by text DEFAULT 'admin'::text)
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

comment on function public.admin_start_inventory_session is 'Ручной старт сессии (волна v0.20.0, Д2): planned → in_progress + ПЕРЕСЧЁТ snapshot листа (остатки могли измениться между планированием и стартом); авто-старта по план-дате нет; параллельные идущие сессии разрешены (ответ 7.3(а) — guard «одна идущая» не делается); из in_progress/done/cancelled — ошибка';

-- ---------- admin_cancel_inventory_session ----------
CREATE OR REPLACE FUNCTION public.admin_cancel_inventory_session(p_session_id integer, p_changed_by text DEFAULT 'admin'::text)
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

comment on function public.admin_cancel_inventory_session is 'Отмена сессии (волна v0.20.0, Д2): planned/in_progress → cancelled (finished_at = now()); из done — ошибка «Завершённую сессию нельзя отменить»; факты листа сохраняются как история, списания не проводятся';

-- ---------- admin_save_inventory_items ----------
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

comment on function public.admin_save_inventory_items is 'Сохранение фактов листа одной транзакцией (волна v0.20.0, Д4; грабля №6 — batch, не построчные запросы): p = {session_id, changed_by?, items: [{item_id, fact_qty}…]}; сессия должна идти (in_progress); fact_qty — целое 0–99999; diff = fact − expected (от snapshot старта) пересчитывается сервером';

-- ---------- admin_finish_inventory_session ----------
CREATE OR REPLACE FUNCTION public.admin_finish_inventory_session(p_session_id integer, p_changed_by text DEFAULT 'admin'::text)
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

comment on function public.admin_finish_inventory_session is 'Завершение сессии одной транзакцией (волна v0.20.0, Д5/Д6 — АН-21 вариант (б) «предупреждение с проведением», решение владельца 7.1 от 10.10.2026): по каждому ненулевому расхождению — строка writeoffs (qty = diff: «−» списание с причиной shortage / «+» излишек surplus, комментарий «Инвентаризация № X») + stock += diff БЕЗ запрета минуса (предупреждение — модалка фронтенда; защита витрины — условное списание create_order); FOR UPDATE в детерминированном порядке variant_id (F23); в ответе — сводка: writeoffs_created, shortages/surpluses (шт), negative_positions (уход в ноль/минус — для протокола); завершение — только роль «администратор» (7.3(б), до M2 — мок-гейт); повторное завершение/завершение отменённой — ошибка; расхождение считается от snapshot старта';

-- ---------- admin_create_writeoff ----------
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

comment on function public.admin_create_writeoff is 'Ручное списание/излишек вне инвентаризации (волна v0.20.0, Д7 — «да, без раздувания карточки товара»: кнопка в журнале «Списания» панели «Инвентаризация»): p = {variant_id, qty (≠0; «−» списание / «+» излишек), reason_id (активная из справочника), comment? ≤1000, changed_by?}; guard stock + qty >= 0 для списаний СОХРАНЁН — минус только через проведение инвентаризации (Д5)';

-- ---------- draft_save_product_badges ----------
CREATE OR REPLACE FUNCTION public.draft_save_product_badges(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_pid_text text;
    v_product_id integer;
    v_ids      jsonb;
    v_seen     integer[] := '{}';
    v_sort     integer := 0;
    v_name     text;
    rec        record;
begin
    if p is null or jsonb_typeof(p) <> 'object' then
        raise exception 'Параметр p — не объект';
    end if;

    v_pid_text := trim(coalesce(p->>'product_id', ''));
    if v_pid_text = '' or v_pid_text ~ '[^0-9]' then
        raise exception 'product_id не указан или не число';
    end if;
    v_product_id := v_pid_text::integer;
    if not exists (select 1 from public.products where id = v_product_id) then
        raise exception 'Товар не найден: id %', v_product_id;
    end if;

    v_ids := coalesce(p->'badge_ids', '[]'::jsonb);
    if jsonb_typeof(v_ids) <> 'array' then
        raise exception 'badge_ids — не массив';
    end if;
    if exists (select 1 from jsonb_array_elements_text(v_ids) as t(v)
                where nullif(trim(t.v), '') is not null
                  and trim(t.v) ~ '[^0-9]') then
        raise exception 'ID бейджа — не число';
    end if;

    -- Замена набора одной транзакцией: delete → insert в порядке массива
    -- (ошибка валидации — откат, товар не остаётся без набора случайно)
    delete from public.product_badges where product_id = v_product_id;

    for rec in
        select nullif(trim(t.v), '')::integer as badge_id
          from jsonb_array_elements_text(v_ids) with ordinality as t(v, ord)
         order by t.ord
    loop
        if rec.badge_id is null then
            continue;                                    -- пустые элементы — пропускаем
        end if;
        if rec.badge_id = any (v_seen) then
            continue;                                    -- дубли — схлопываются
        end if;
        select b.name into v_name
          from public.badges b
         where b.id = rec.badge_id and b.is_active;
        if v_name is null then
            raise exception 'Бейдж не найден или неактивен: id %', rec.badge_id;
        end if;
        v_seen := v_seen || rec.badge_id;
        v_sort := v_sort + 1;
        insert into public.product_badges (product_id, badge_id, sort_order)
        values (v_product_id, rec.badge_id, v_sort);
    end loop;

    return jsonb_build_object('ok', true, 'count', v_sort);
end;
$$;

comment on function public.draft_save_product_badges is 'v1 (волна v0.21.0, fp №16 — бейджи; Д3): сохранение набора бейджей товара одной транзакцией — delete → insert в порядке массива (sort_order = позиция); дубли схлопываются; валидации: товар существует, badge_ids — массив чисел, каждый бейдж активен; пустой массив = снять все (в т.ч. New — снятие только ручное, ответ 7.4); p = { product_id, badge_ids: [int] } → { ok, count }; прототип боевого PATCH /api/products/:id/badges';

-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = any (array['draft_phone_key', 'draft_email_key', 'check_promo', 'create_order', 'admin_set_status', 'admin_set_paid', 'track_order', 'draft_save_look', 'create_return_request', 'admin_set_return_status', 'admin_set_return_refund', 'admin_resolve_quarantine', 'admin_update_client', 'admin_create_inventory_session', 'admin_start_inventory_session', 'admin_cancel_inventory_session', 'admin_save_inventory_items', 'admin_finish_inventory_session', 'admin_create_writeoff', 'draft_save_product_badges']))            as core_20,     -- ждём 20
    (select obj_description(oid,'pg_proc') like 'v9%' from pg_proc where proname = 'create_order')  as order_v9,   -- ждём t
    (select obj_description(oid,'pg_proc') like 'v2%' from pg_proc where proname = 'check_promo')  as promo_v2,   -- ждём t
    (select to_regprocedure('public.draft_save_product_badges(jsonb)') is not null)                 as badges_rpc; -- ждём t
-- Ожидаемая строка самопроверки (psql -At): 20|t|t|t
