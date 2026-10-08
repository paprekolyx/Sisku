-- ============================================================================
--  SISKU (черновик) — СКРИПТ 3: функции ядра (12) — конечные версии на v0.16.0
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE (волна v0.17.0, 07.10.2026): состояние базы на
--  v0.16.0-draft одним скриптом. Заменяет исторические скрипты 03, 10 (check_promo, track_order v1), 16 (create_order v6), 17, 18, 19 (create_order v7), 22 (track_order v2, RPC возвратов), 23 (admin_set_status v4, admin_resolve_quarantine).
--  Исторические версии (включая промежуточные версии функций) — замороженный
--  архив supabase/archive/sql-01-25-v0160.md и git-история; номера удалённых
--  скриптов не переиспользуются (SQL-регламент).
--  Идемпотентен: create or replace function — тела конечных версий (v0.16.0).
--  Порядок для НОВОГО стенда: 01 → 02 → 03 → 04 → 05 → 09 → 26 → 27.
--  ⚠ НА ЖИВОЙ БАЗЕ (контент отредактирован владельцем) baseline НЕ
--  перезапускать — модель F21: живая база получает только инкременты ≥ 26.
-- ============================================================================


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
    if v_promo.valid_from is not null and current_date < v_promo.valid_from then
        return jsonb_build_object('ok', false, 'error', 'Промокод ещё не действует');
    end if;
    if v_promo.valid_until is not null and current_date > v_promo.valid_until then
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
begin
    v_name    := nullif(btrim(coalesce(p->>'customer_name', '')), '');
    v_phone   := nullif(btrim(coalesce(p->>'customer_phone', '')), '');
    v_email   := nullif(lower(btrim(coalesce(p->>'customer_email', ''))), '');
    v_address := nullif(btrim(coalesce(p->>'customer_address', '')), '');
    v_comment := nullif(btrim(coalesce(p->>'comment', '')), '');
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


comment on function public.create_order is 'v7 (скрипт 19, волна v0.15.0, правка 2.20): v6 + защита имени клиента — если clients.name_confirmed установлен администратором, full_name не перезаписывается новым заказом (минимальная политика до П8а); вся логика v6 (скрипт 16: UPSERT клиента, блокировка и условный инкремент промокода, нормализация дублей, greatest 0, join vr.product_id, анти-спам по draft_phone_key, детерминированные блокировки) сохранена без изменений';


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


-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public')                                       as functions_total, -- ждём 12
    (select prosrc like '%name_confirmed%' from pg_proc
      where proname = 'create_order')                                   as create_order_v7, -- ждём t
    (select prosrc like '%quarantine_qty = quarantine_qty + v_item.quantity%'
      from pg_proc where proname = 'admin_set_status')                  as set_status_v4,   -- ждём t
    (select prosrc like '%return_available%' from pg_proc
      where proname = 'track_order')                                    as track_v2,        -- ждём t
    (select count(*) from pg_proc where proname in
      ('create_return_request','admin_set_return_status',
       'admin_set_return_refund','admin_resolve_quarantine',
       'draft_save_look'))                                              as wave_fns;        -- ждём 5
