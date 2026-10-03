-- ============================================================================
--  SISKU (черновик) — СКРИПТ 15: клиентская база + данные для статистики акций
-- ============================================================================
--  1. Таблица clients: нормализованная клиентская база. Заказ и клиент —
--     связь «один ко многим» (orders.client_id), ПРОМЕЖУТОЧНАЯ таблица не
--     нужна: она применяется только для связей «многие ко многим».
--     Дедупликация: телефон приводится к ключу 7XXXXXXXXXX (8 → 7),
--     e-mail — к нижнему регистру; один человек = одна строка clients.
--  2. Миграция существующих заказов: клиенты выделяются из orders
--     (имя/контакты последнего заказа), все заказы связываются client_id-ом.
--  3. Колонки promo_discount и look_discount в orders: фактические суммы
--     скидок заказа (раньше хранилась только итоговая сумма — для статистики
--     акций нужны отдельные числа). Заполняются для старых заказов расчётом
--     из снапшотов позиций, для новых — пишутся в create_order v5.
--  4. create_order v5: находит или создаёт клиента (по ключу телефона, затем
--     e-mail), связывает заказ, пишет суммы скидок. Остальная логика v4
--     (серверные цены, промокод, комплект, анти-спам) сохранена без изменений.
--  5. draft_admin_bundle v2: добавлен блок promos (promo_codes) — подвкладка
--     статистики «Акции» грузится тем же одним запросом.
--  6. draft_clients_bundle(): клиенты + агрегаты по их заказам одним запросом
--     для страницы «Пользователи → Клиенты» (реальные данные вместо мока).
--  Черновик: чтение/запись clients для anon открыты политиками draft_*
--  (как у остальных таблиц) — ТОЛЬКО тестовые данные, Supabase вне РФ.
--  В боевой версии — серверный API с ролями и база в РФ (152-ФЗ).
--  Идемпотентен: повторный запуск безопасен (миграции пропускают уже
--  связанные заказы и уже заполненные скидки).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: убеждаемся, что мы в проекте черновика Sisku, а не в учебном.
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.orders') is null
       or to_regclass('public.promo_codes') is null
       or to_regclass('public.looks') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (orders / promo_codes / looks). Проверьте переключатель проектов Supabase слева вверху: нужен проект sisku-draft, а не учебный.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Ключи дедупликации (общие для миграции, create_order и страницы клиентов)
-- ----------------------------------------------------------------------------
create or replace function public.draft_phone_key(p text)
returns text
language sql immutable
as $$
    select case
             when x.digits is null then null
             when length(x.digits) = 11 and left(x.digits, 1) = '8'
                 then '7' || substr(x.digits, 2)
             else x.digits
           end
    from (select nullif(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '')) as x(digits);
$$;
comment on function public.draft_phone_key(text) is
    'Нормализованный телефон для дедупликации: только цифры, ведущая 8 заменяется на 7';

create or replace function public.draft_email_key(p text)
returns text
language sql immutable
as $$
    select nullif(lower(btrim(coalesce(p, ''))), '');
$$;
comment on function public.draft_email_key(text) is
    'Нормализованный e-mail для дедупликации: trim + нижний регистр';

-- ----------------------------------------------------------------------------
-- 2. Таблица клиентов
-- ----------------------------------------------------------------------------
create table if not exists public.clients (
    id         serial primary key,
    full_name  text not null,
    phone      text,
    email      text,
    address    text,                          -- последний адрес доставки из заказов
    note       text,                          -- комментарий менеджера
    phone_key  text unique,                   -- 7XXXXXXXXXX или null
    email_key  text unique,                   -- нижний регистр или null
    created_at timestamptz not null default now(),   -- дата первого заказа
    updated_at timestamptz not null default now()
);
comment on table public.clients is
    'Клиентская база: один клиент = один телефон/e-mail; заказы связаны через orders.client_id';

alter table public.clients enable row level security;

drop policy if exists draft_anon_read_clients on public.clients;
create policy draft_anon_read_clients on public.clients
    for select to anon, authenticated using (true);      -- черновик: только тестовые данные

drop policy if exists draft_anon_write_clients on public.clients;
create policy draft_anon_write_clients on public.clients
    for insert to anon, authenticated with check (true); -- черновик

drop policy if exists draft_anon_update_clients on public.clients;
create policy draft_anon_update_clients on public.clients
    for update to anon, authenticated using (true) with check (true);

drop policy if exists draft_anon_delete_clients on public.clients;
create policy draft_anon_delete_clients on public.clients
    for delete to anon, authenticated using (true);

-- ----------------------------------------------------------------------------
-- 3. Новые колонки заказов + индексы
-- ----------------------------------------------------------------------------
alter table public.orders add column if not exists client_id integer references public.clients(id) on delete set null;
comment on column public.orders.client_id is 'Клиент заказа (связь «один ко многим», промежуточная таблица не нужна)';

alter table public.orders add column if not exists promo_discount numeric(10,2) not null default 0;
comment on column public.orders.promo_discount is 'Фактическая скидка промокода, ₽ (считает сервер)';

alter table public.orders add column if not exists look_discount numeric(10,2) not null default 0;
comment on column public.orders.look_discount is 'Фактическая скидка комплекта, ₽ (считает сервер)';

create index if not exists idx_orders_client_id on public.orders (client_id);
create index if not exists idx_orders_promo_code_id on public.orders (promo_code_id);

-- ----------------------------------------------------------------------------
-- 4. Миграция: выделяем клиентов из существующих заказов и связываем их.
--    Проход в хронологии заказов: created_at клиента = первый заказ,
--    имя и контакты освежаются последним заказом. Повторный запуск: заказов
--    без client_id уже нет — цикл пустой.
-- ----------------------------------------------------------------------------
do $$
declare
    o        record;
    v_pkey   text;
    v_ekey   text;
    v_client integer;
begin
    for o in
        select id, customer_name, customer_phone, customer_email, customer_address, created_at
        from public.orders
        where client_id is null
        order by created_at, id
    loop
        v_pkey := public.draft_phone_key(o.customer_phone);
        v_ekey := public.draft_email_key(o.customer_email);
        v_client := null;

        if v_pkey is not null then
            select id into v_client from public.clients where phone_key = v_pkey limit 1;
        end if;
        if v_client is null and v_ekey is not null then
            select id into v_client from public.clients where email_key = v_ekey limit 1;
        end if;

        if v_client is null then
            insert into public.clients (full_name, phone, email, address, phone_key, email_key, created_at)
            values (o.customer_name, o.customer_phone, o.customer_email, o.customer_address,
                    v_pkey, v_ekey, o.created_at)
            returning id into v_client;
        else
            update public.clients
               set full_name  = o.customer_name,
                   phone      = coalesce(o.customer_phone, phone),
                   email      = coalesce(o.customer_email, email),
                   address    = coalesce(o.customer_address, address),
                   phone_key  = coalesce(phone_key, v_pkey),
                   email_key  = coalesce(email_key, v_ekey),
                   updated_at = now()
             where id = v_client;
        end if;

        update public.orders set client_id = v_client where id = o.id;
    end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 5. Миграция: фактические скидки старых заказов.
--    total = сумма позиций − скидка промокода − скидка комплекта, поэтому:
--    скидка комплекта повторяет серверную формулу (цена позиции лука × процент,
--    по одному разу на позицию лука), скидка промокода — остаток разницы.
--    Условие promo_discount = 0 and look_discount = 0 делает повторный запуск
--    безопасным: уже заполненные заказы не трогаются.
-- ----------------------------------------------------------------------------
do $$
declare
    o        record;
    v_items  numeric(10,2);
    v_sum    numeric(10,2);
    v_pct    numeric(5,2);
    v_look_d numeric(10,2);
    v_promo_d numeric(10,2);
begin
    for o in
        select id, look_id, total
        from public.orders
        where (promo_code_id is not null or look_id is not null)
          and promo_discount = 0
          and look_discount = 0
        order by id
    loop
        select coalesce(sum(i.price * i.quantity), 0) into v_items
        from public.order_items i
        where i.order_id = o.id;

        v_look_d := 0;
        if o.look_id is not null then
            select l.discount_percent into v_pct
            from public.looks l
            where l.id = o.look_id;

            if v_pct is not null then
                select coalesce(sum(x.p), 0) into v_sum
                from public.look_items li
                join lateral (
                    select max(i.price) as p
                    from public.order_items i
                    where i.order_id = o.id
                      and i.product_id = li.product_id
                      and (li.variant_id is null or i.variant_id = li.variant_id)
                ) x on x.p is not null
                where li.look_id = o.look_id;

                v_look_d := round(v_sum * v_pct / 100, 2);
            end if;
        end if;

        v_promo_d := greatest(v_items - o.total - v_look_d, 0);

        update public.orders
           set look_discount  = v_look_d,
               promo_discount = v_promo_d
         where id = o.id;
    end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 6. create_order v5: клиентская база + фактические скидки.
--    Логика v4 (серверные цены/остатки, промокод, частичный комплект,
--    анти-спам 3/10мин) сохранена полностью.
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

    if v_promo_code <> '' then
        v_chk := public.check_promo(v_promo_code, v_total);
        if coalesce((v_chk->>'ok')::boolean, false) then
            v_discount := (v_chk->>'discount_amount')::numeric(10,2);
            select id into v_promo_id from public.promo_codes where code = v_promo_code;
        else
            raise exception '%', coalesce(v_chk->>'error', 'Промокод не применён');
        end if;
    end if;

    -- клиентская база (v0.13.0): ищем клиента по ключу телефона, затем e-mail;
    -- не найден — создаём. Имя и контакты освежаются данными нового заказа.
    if v_pkey is not null then
        select id into v_client_id from public.clients where phone_key = v_pkey limit 1;
    end if;
    if v_client_id is null and v_ekey is not null then
        select id into v_client_id from public.clients where email_key = v_ekey limit 1;
    end if;
    if v_client_id is null then
        insert into public.clients (full_name, phone, email, address, phone_key, email_key, created_at)
        values (v_name, v_phone, v_email, v_address, v_pkey, v_ekey, now())
        returning id into v_client_id;
    else
        update public.clients
           set full_name  = v_name,
               phone      = coalesce(v_phone, phone),
               email      = coalesce(v_email, email),
               address    = coalesce(v_address, address),
               phone_key  = coalesce(phone_key, v_pkey),
               email_key  = coalesce(email_key, v_ekey),
               updated_at = now()
         where id = v_client_id;
    end if;

    select id into v_status_new from public.order_statuses where code = 'new';

    insert into public.orders (
        customer_name, customer_phone, customer_email, customer_address,
        status_id, payment_method_id, delivery_method_id,
        total, delivery_cost, comment, promo_code_id, look_id,
        client_id, promo_discount, look_discount
    ) values (
        v_name, v_phone, v_email, v_address,
        v_status_new, v_payment, v_delivery,
        v_total - v_discount - v_look_disc, v_deliv_cost, v_comment, v_promo_id, v_look_id,
        v_client_id, v_discount, v_look_disc
    ) returning id into v_order_id;

    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_qty := (v_item->>'quantity')::integer;

        insert into public.order_items (
            order_id, product_id, variant_id, quantity, price, title_snapshot, variant_snapshot
        )
        select v_order_id, pr.id, vr.id, v_qty, pr.price, pr.name, vr.label
        from public.products pr
        join public.product_variants vr on vr.id = (v_item->>'variant_id')::integer
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
        'client_id', v_client_id,
        'total', v_total - v_discount - v_look_disc,
        'discount', v_discount,
        'look_discount', v_look_disc,
        'delivery_cost', v_deliv_cost,
        'grand_total', v_total - v_discount - v_look_disc + v_deliv_cost);
end;
$$;

comment on function public.create_order(jsonb) is
    'v5: серверные цены, промокод, частичный комплект + клиентская база (client_id) и фактические скидки promo_discount/look_discount';

-- ----------------------------------------------------------------------------
-- 7. draft_admin_bundle v2: блок promos для подвкладки статистики «Акции»
-- ----------------------------------------------------------------------------
create or replace function public.draft_admin_bundle()
returns jsonb
language sql security definer set search_path = public
as $$
select jsonb_build_object(
    'orders',      (select coalesce(jsonb_agg(o order by o.created_at desc), '[]'::jsonb)
                      from public.orders o),
    'items',       (select coalesce(jsonb_agg(t), '[]'::jsonb)
                      from public.order_items t),
    'statuses',    (select coalesce(jsonb_agg(s order by s.sort_order), '[]'::jsonb)
                      from public.order_statuses s),
    'transitions', (select coalesce(jsonb_agg(t), '[]'::jsonb)
                      from public.status_transitions t),
    'payments',    (select coalesce(jsonb_agg(m order by m.id), '[]'::jsonb)
                      from public.payment_methods m),
    'deliveries',  (select coalesce(jsonb_agg(m order by m.id), '[]'::jsonb)
                      from public.delivery_methods m),
    'history',     (select coalesce(jsonb_agg(h), '[]'::jsonb)
                      from public.order_status_history h),
    'promos',      (select coalesce(jsonb_agg(pc order by pc.code), '[]'::jsonb)
                      from public.promo_codes pc)
);
$$;

comment on function public.draft_admin_bundle() is
    'Черновик: весь набор данных админки одним запросом; v2 — добавлен блок promos (статистика акций)';

-- ----------------------------------------------------------------------------
-- 8. draft_clients_bundle(): страница «Пользователи → Клиенты» одним запросом
-- ----------------------------------------------------------------------------
create or replace function public.draft_clients_bundle()
returns jsonb
language sql security definer set search_path = public
as $$
select jsonb_build_object(
    'clients', (select coalesce(jsonb_agg(c order by c.created_at desc, c.id desc), '[]'::jsonb)
                  from public.clients c),
    'stats',   (select coalesce(jsonb_agg(jsonb_build_object(
                    'client_id',   s.client_id,
                    'orders',      s.orders_cnt,
                    'sum',         s.sum_total,
                    'paid_sum',    s.sum_paid,
                    'first_order', s.first_order,
                    'last_order',  s.last_order
                )), '[]'::jsonb)
                  from (select o.client_id                            as client_id,
                               count(*)                               as orders_cnt,
                               sum(o.total + o.delivery_cost)         as sum_total,
                               sum(case when o.is_paid then o.total + o.delivery_cost
                                        else 0 end)                   as sum_paid,
                               min(o.created_at)                      as first_order,
                               max(o.created_at)                      as last_order
                          from public.orders o
                         where o.client_id is not null
                         group by o.client_id) s)   -- агрегаты считаем в подзапросе:
                                                    -- count(*) внутри jsonb_agg = ошибка 42803
);
$$;

comment on function public.draft_clients_bundle() is
    'Черновик: клиенты + агрегаты их заказов (кол-во, суммы, даты) одним запросом; v2 — двухступенчатая агрегация статистики (fix 42803)';

-- ----------------------------------------------------------------------------
-- 9. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.clients)                             as clients_total,
    (select count(*) from public.orders where client_id is not null)  as orders_linked,   -- = orders_total
    (select count(*) from public.orders)                              as orders_total,
    (select count(*) from public.orders
      where (promo_code_id is not null or look_id is not null)
        and promo_discount = 0 and look_discount = 0)                 as discounts_missing, -- ожидаем 0
    (select count(*) from jsonb_array_elements(draft_admin_bundle()  -> 'promos'))  as promos_in_bundle,
    (select count(*) from jsonb_array_elements(draft_clients_bundle() -> 'clients')) as clients_in_bundle,
    (select count(*) from pg_policies
      where tablename = 'clients' and policyname like 'draft_anon_%') as client_policies;  -- ожидаем 4
