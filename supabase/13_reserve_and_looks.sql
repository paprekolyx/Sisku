-- ============================================================================
--  SISKU (черновик) — СКРИПТ 13: резервирование на время сборки + комплекты
-- ============================================================================
--  1. РЕЗЕРВИРОВАНИЕ. Остаток списывается в момент создания заказа
--     (create_order), то есть товар уже «зарезервирован» под заказ.
--     НОВОЕ: при отмене заказа (статус cancelled) и при возврате (returned)
--     остатки возвращаются на склад автоматически — admin_set_status v2.
--     Функция draft_reserved_map() отдаёт количество единиц каждого
--     варианта, зарезервированное открытыми заказами
--     (new / confirmed / paid / packing) — для колонки «В резерве».
--  2. КОМПЛЕКТЫ (луки): таблицы looks и look_items + скидка комплекта.
--     create_order v3 принимает look_id: проверяет, что все позиции комплекта
--     лежат в корзине, и даёт скидку процента комплекта на их сумму.
--     Скидка считается НА СЕРВЕРЕ, как и промокоды.
--  3. Черновые политики anon-записи для looks/look_items (CRUD из админки).
--  Идемпотентен.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: убеждаемся, что мы в проекте черновика Sisku, а не в учебном
--    (правило 6 supabase/README.md; добавлен в v0.14.0 по ревью F20).
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.product_variants') is null
       or to_regclass('public.orders') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (product_variants / orders). Проверьте переключатель проектов Supabase слева вверху: нужен проект sisku-draft, а не учебный.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Таблицы комплектов
-- ----------------------------------------------------------------------------
create table if not exists public.looks (
    id               serial primary key,
    title            text not null,
    description      text,
    discount_percent numeric(5,2) not null default 0 check (discount_percent between 0 and 90),
    is_active        boolean not null default true,
    created_at       timestamptz not null default now()
);
comment on table public.looks is 'Луки / готовые образы: состав и скидка комплекта';

create table if not exists public.look_items (
    id         serial primary key,
    look_id    integer not null references public.looks(id) on delete cascade,
    product_id integer not null references public.products(id),
    variant_id integer references public.product_variants(id),
    sort_order integer not null default 1
);
comment on table public.look_items is 'Позиции комплекта: товар + конкретный вариант (размер/объём)';

alter table public.looks enable row level security;
alter table public.look_items enable row level security;

drop policy if exists draft_anon_read_looks on public.looks;
create policy draft_anon_read_looks on public.looks
    for select to anon, authenticated using (true);
drop policy if exists draft_anon_write_looks on public.looks;
create policy draft_anon_write_looks on public.looks
    for insert to anon, authenticated with check (true);
drop policy if exists draft_anon_update_looks on public.looks;
create policy draft_anon_update_looks on public.looks
    for update to anon, authenticated using (true) with check (true);
drop policy if exists draft_anon_delete_looks on public.looks;
create policy draft_anon_delete_looks on public.looks
    for delete to anon, authenticated using (true);

drop policy if exists draft_anon_read_look_items on public.look_items;
create policy draft_anon_read_look_items on public.look_items
    for select to anon, authenticated using (true);
drop policy if exists draft_anon_write_look_items on public.look_items;
create policy draft_anon_write_look_items on public.look_items
    for insert to anon, authenticated with check (true);
drop policy if exists draft_anon_update_look_items on public.look_items;
create policy draft_anon_update_look_items on public.look_items
    for update to anon, authenticated using (true) with check (true);
drop policy if exists draft_anon_delete_look_items on public.look_items;
create policy draft_anon_delete_look_items on public.look_items
    for delete to anon, authenticated using (true);

alter table public.orders add column if not exists look_id integer references public.looks(id);
comment on column public.orders.look_id is 'Комплект, если заказ оформлен целиком из лука';

-- ----------------------------------------------------------------------------
-- 2. Карта резервов: сколько единиц варианта зарезервировано открытыми заказами
-- ----------------------------------------------------------------------------
create or replace function public.draft_reserved_map()
returns jsonb
language sql security definer set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object('variant_id', t.variant_id, 'reserved', t.qty)), '[]'::jsonb)
from (
    select i.variant_id, sum(i.quantity) as qty
    from public.order_items i
    join public.orders o on o.id = i.order_id
    join public.order_statuses s on s.id = o.status_id
    where s.code in ('new', 'confirmed', 'paid', 'packing')
      and i.variant_id is not null
    group by i.variant_id
) t;
$$;

-- ----------------------------------------------------------------------------
-- 3. admin_set_status v2: возврат остатков при отмене и возврате заказа
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_status(
    p_order_id   integer,
    p_status_code text,
    p_comment    text default null,
    p_changed_by text default 'admin'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_from integer;
    v_to   integer;
    v_from_name text;
    v_to_name   text;
    v_item      record;
begin
    select status_id into v_from from public.orders where id = p_order_id;
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

    -- резервирование: отмена и возврат возвращают остатки на склад
    if p_status_code in ('cancelled', 'returned') then
        for v_item in
            select variant_id, quantity from public.order_items
            where order_id = p_order_id and variant_id is not null
        loop
            update public.product_variants
               set stock = stock + v_item.quantity
             where id = v_item.variant_id;
        end loop;
    end if;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (p_order_id, v_to, p_changed_by, p_comment);

    return jsonb_build_object('ok', true, 'status', p_status_code, 'status_name', v_to_name);
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. create_order v3: скидка комплекта (look_id) поверх промокода
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
    v_look_id    integer;
    v_look       public.looks%rowtype;
    v_look_item  record;
    v_look_sum   numeric(10,2) := 0;
    v_look_disc  numeric(10,2) := 0;
    v_found      boolean;
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

    -- комплект: все позиции лука должны быть в корзине, скидка — на их сумму
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
                  and (x->>'variant_id')::integer = coalesce(v_look_item.variant_id, (x->>'variant_id')::integer)
            ) into v_found;
            if not v_found then
                raise exception 'Комплект «%» неполный в корзине', v_look.title;
            end if;
            v_look_sum := v_look_sum + v_look_item.price;
        end loop;
        v_look_disc := round(v_look_sum * v_look.discount_percent / 100, 2);
    end if;

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
        total, delivery_cost, comment, promo_code_id, look_id
    ) values (
        v_name, v_phone, v_email, v_address,
        v_status_new, v_payment, v_delivery,
        v_total - v_discount - v_look_disc, v_deliv_cost, v_comment, v_promo_id, v_look_id
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
        'total', v_total - v_discount - v_look_disc,
        'discount', v_discount,
        'look_discount', v_look_disc,
        'delivery_cost', v_deliv_cost,
        'grand_total', v_total - v_discount - v_look_disc + v_deliv_cost);
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_policies where tablename in ('looks', 'look_items') and policyname like 'draft_anon_%') as look_policies,
    (select column_name from information_schema.columns
      where table_name = 'orders' and column_name = 'look_id') as look_column_ok;
