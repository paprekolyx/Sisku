-- ============================================================================
--  SISKU (черновик) — СКРИПТ 10: промокоды и отслеживание заказа покупателем
-- ============================================================================
--  1. Таблица promo_codes (референс — учебный проект): тип скидки
--     (percent/fixed), значение, минимальная сумма, срок действия,
--     лимит использований, счётчик, активность.
--  2. check_promo(code, total) — проверка кода НА СЕРВЕРЕ: публичного чтения
--     промокодов витриной нет, клиент узнаёт только результат применения.
--  3. create_order v2: принимает промокод, пересчитывает сумму НА СЕРВЕРЕ
--     (подменить скидку из браузера нельзя), пишет promo_code_id и
--     увеличивает used_count в одной транзакции с заказом.
--  4. track_order(order_id, tail) — отслеживание статуса покупателем:
--     номер заказа + последние 4 цифры телефона ИЛИ первые 4 символа почты
--     до @. Возвращает только историю статусов с датами — без упоминания
--     администраторов и ролей.
--  Черновик: чтение/запись promo_codes для anon открыты политикой draft_*
--  (страница «Магазин» без авторизации); в боевой версии останется только
--  серверный доступ. Идемпотентен.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Таблица промокодов
-- ----------------------------------------------------------------------------
create table if not exists public.promo_codes (
    id               serial primary key,
    code             text not null unique,
    discount_type    text not null check (discount_type in ('percent', 'fixed')),
    discount_value   numeric(10,2) not null check (discount_value > 0),
    min_order_amount numeric(10,2) not null default 0,
    valid_from       date,
    valid_until      date,
    usage_limit      integer,                      -- пусто — без лимита
    used_count       integer not null default 0,
    is_active        boolean not null default true,
    created_at       timestamptz not null default now()
);
comment on table public.promo_codes is 'Промокоды: проверка и применение только через серверные функции';

alter table public.promo_codes enable row level security;

drop policy if exists draft_anon_read_promo on public.promo_codes;
create policy draft_anon_read_promo on public.promo_codes
    for select to anon, authenticated using (true);      -- черновик: страница «Магазин»

drop policy if exists draft_anon_write_promo on public.promo_codes;
create policy draft_anon_write_promo on public.promo_codes
    for insert to anon, authenticated with check (true); -- черновик

drop policy if exists draft_anon_update_promo on public.promo_codes;
create policy draft_anon_update_promo on public.promo_codes
    for update to anon, authenticated using (true) with check (true);

alter table public.orders add column if not exists promo_code_id integer references public.promo_codes(id);
comment on column public.orders.promo_code_id is 'Промокод заказа, если применялся';

-- ----------------------------------------------------------------------------
-- 2. Проверка промокода (сервер)
-- ----------------------------------------------------------------------------
create or replace function public.check_promo(p_code text, p_total numeric)
returns jsonb
language plpgsql security definer set search_path = public
as $$
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

-- ----------------------------------------------------------------------------
-- 3. create_order v2: промокод применяется и пересчитывается на сервере
-- ----------------------------------------------------------------------------
create or replace function public.create_order(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
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
    v_prod      record;
    v_total     numeric(10,2) := 0;
    v_deliv_cost numeric(10,2) := 0;
    v_order_id  integer;
    v_status_new integer;
    v_recent    integer;
    v_promo_code text;
    v_promo_id   integer;
    v_discount   numeric(10,2) := 0;
    v_chk        jsonb;
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

    select count(*) into v_recent
    from public.orders
    where created_at > now() - interval '10 minutes'
      and ((v_phone is not null and customer_phone = v_phone)
        or (v_email is not null and lower(coalesce(customer_email,'')) = v_email));
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

    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_qty := coalesce((v_item->>'quantity')::integer, 0);
        if v_qty < 1 or v_qty > 99 then
            raise exception 'Некорректное количество товара';
        end if;

        select pr.id, pr.name, pr.price, pr.is_active, vr.id as variant_id, vr.label, vr.stock
        into v_prod
        from public.products pr
        join public.product_variants vr on vr.product_id = pr.id
        where pr.id = (v_item->>'product_id')::integer
          and vr.id = (v_item->>'variant_id')::integer
        for update of pr, vr;

        if v_prod.id is null or not v_prod.is_active then
            raise exception 'Товар недоступен для заказа';
        end if;
        if v_prod.stock < v_qty then
            raise exception 'Недостаточно остатка: % (%), осталось % шт.', v_prod.name, v_prod.label, v_prod.stock;
        end if;

        v_total := v_total + v_prod.price * v_qty;
    end loop;

    -- промокод: проверка и расчёт скидки только на сервере
    if v_promo_code <> '' then
        v_chk := public.check_promo(v_promo_code, v_total);
        if coalesce((v_chk->>'ok')::boolean, false) then
            v_discount := (v_chk->>'discount_amount')::numeric(10,2);
            select id into v_promo_id from public.promo_codes where code = v_promo_code;
        else
            raise exception '%', coalesce(v_chk->>'error', 'Промокод не применён');
        end if;
    end if;

    select id into v_status_new from public.order_statuses where code = 'new';

    insert into public.orders (
        customer_name, customer_phone, customer_email, customer_address,
        status_id, payment_method_id, delivery_method_id,
        total, delivery_cost, comment, promo_code_id
    ) values (
        v_name, v_phone, v_email, v_address,
        v_status_new, v_payment, v_delivery,
        v_total - v_discount, v_deliv_cost, v_comment, v_promo_id
    ) returning id into v_order_id;

    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_qty := (v_item->>'quantity')::integer;

        insert into public.order_items (
            order_id, product_id, variant_id, quantity, price, title_snapshot, variant_snapshot
        )
        select v_order_id, pr.id, vr.id, v_qty, pr.price, pr.name, vr.label
        from public.products pr
        join public.product_variants vr on vr.product_id = pr.id
        where pr.id = (v_item->>'product_id')::integer
          and vr.id = (v_item->>'variant_id')::integer;

        update public.product_variants vr
           set stock = stock - v_qty
         where vr.id = (v_item->>'variant_id')::integer;
    end loop;

    if v_promo_id is not null then
        update public.promo_codes set used_count = used_count + 1 where id = v_promo_id;
    end if;

    insert into public.deliveries (order_id, delivery_method_id, address, cost)
    select v_order_id, v_delivery, v_address, v_deliv_cost;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (v_order_id, v_status_new, 'system', 'Заказ создан на сайте');

    return jsonb_build_object(
        'order_id', v_order_id,
        'total', v_total - v_discount,
        'discount', v_discount,
        'delivery_cost', v_deliv_cost,
        'grand_total', v_total - v_discount + v_deliv_cost);
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Отслеживание заказа покупателем (без упоминания ролей и админов)
-- ----------------------------------------------------------------------------
create or replace function public.track_order(p_order_id integer, p_tail text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_order    public.orders%rowtype;
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

    select coalesce(jsonb_agg(jsonb_build_object(
        'status', s.name,
        'changed_at', h.changed_at,
        'comment', h.comment) order by h.changed_at), '[]'::jsonb)
    into v_history
    from public.order_status_history h
    join public.order_statuses s on s.id = h.status_id
    where h.order_id = v_order.id;

    return jsonb_build_object(
        'found', true,
        'created_at', v_order.created_at,
        'total', v_order.total + v_order.delivery_cost,
        'history', v_history);
end;
$$;

comment on function public.track_order(integer, text) is
    'Отслеживание заказа покупателем: номер + последние 4 цифры телефона или 4 символа почты до @';

-- ----------------------------------------------------------------------------
-- 5. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.promo_codes) as promo_rows,
    (select column_name from information_schema.columns
      where table_name = 'orders' and column_name = 'promo_code_id') as promo_column_ok;
