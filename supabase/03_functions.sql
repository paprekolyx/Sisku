-- ============================================================================
--  SISKU (черновик) — СКРИПТ 3: серверные функции
-- ============================================================================
--  create_order(p jsonb)      — приём заказа (сильное решение учебного проекта):
--      • цены и остатки берутся ИЗ БАЗЫ, присланные браузером игнорируются —
--        подменить стоимость из консоли нельзя;
--      • заказ, позиции, доставка и первая запись истории — в одной транзакции;
--      • снапшоты цены, названия и размера в order_items;
--      • списание остатков варианта;
--      • валидация: имя обязательно, телефон или e-mail обязателен,
--        количество 1–99, не более 50 позиций, только активные товары;
--      • анти-спам: не более 3 заказов за 10 минут с одного телефона/e-mail.
--  admin_set_status(...)      — смена статуса с проверкой status_transitions
--                               + запись в order_status_history.
--  admin_set_paid(...)        — признак оплаты + дата (признак, а не статус).
--
--  Все функции security definer: выполняются от владельца таблиц поверх RLS,
--  поэтому прямого INSERT/UPDATE для anon не существует.
--  Скрипт идемпотентен: create or replace function.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Приём заказа
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
begin
    v_name    := nullif(btrim(coalesce(p->>'customer_name', '')), '');
    v_phone   := nullif(btrim(coalesce(p->>'customer_phone', '')), '');
    v_email   := nullif(lower(btrim(coalesce(p->>'customer_email', ''))), '');
    v_address := nullif(btrim(coalesce(p->>'customer_address', '')), '');
    v_comment := nullif(btrim(coalesce(p->>'comment', '')), '');
    v_payment := (p->>'payment_method_id')::integer;
    v_delivery:= (p->>'delivery_method_id')::integer;
    v_items   := coalesce(p->'items', '[]'::jsonb);

    -- валидация входных данных
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

    -- анти-спам: не более 3 заказов за 10 минут с телефона или e-mail
    select count(*) into v_recent
    from public.orders
    where created_at > now() - interval '10 minutes'
      and ((v_phone is not null and customer_phone = v_phone)
        or (v_email is not null and lower(coalesce(customer_email,'')) = v_email));
    if v_recent >= 3 then
        raise exception 'Слишком много заказов подряд. Пожалуйста, попробуйте через несколько минут';
    end if;

    -- способы оплаты и доставки должны существовать и быть активными
    if not exists (select 1 from public.payment_methods where id = v_payment and is_active) then
        raise exception 'Некорректный способ оплаты';
    end if;
    select base_price into v_deliv_cost
    from public.delivery_methods
    where id = v_delivery and is_active;
    if v_deliv_cost is null then
        raise exception 'Некорректный способ доставки';
    end if;

    -- позиции: цены и остатки ТОЛЬКО из базы
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

    -- статус «новый»
    select id into v_status_new from public.order_statuses where code = 'new';

    -- заказ + позиции + доставка + история одной транзакцией
    insert into public.orders (
        customer_name, customer_phone, customer_email, customer_address,
        status_id, payment_method_id, delivery_method_id,
        total, delivery_cost, comment
    ) values (
        v_name, v_phone, v_email, v_address,
        v_status_new, v_payment, v_delivery,
        v_total, v_deliv_cost, v_comment
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

        -- списание остатка
        update public.product_variants vr
           set stock = stock - v_qty
         where vr.id = (v_item->>'variant_id')::integer;
    end loop;

    insert into public.deliveries (order_id, delivery_method_id, address, cost)
    select v_order_id, v_delivery, v_address, v_deliv_cost;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (v_order_id, v_status_new, 'system', 'Заказ создан на сайте');

    -- клиенту возвращаем только номер и суммы, ничего лишнего
    return jsonb_build_object(
        'order_id', v_order_id,
        'total', v_total,
        'delivery_cost', v_deliv_cost,
        'grand_total', v_total + v_deliv_cost
    );
end;
$$;

comment on function public.create_order(jsonb) is
    'Единственная точка создания заказа: цены и остатки из базы, всё в одной транзакции';

-- ----------------------------------------------------------------------------
-- 2. Смена статуса с проверкой модели переходов
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

    -- разрешён ли переход моделью (status_transitions)
    if not exists (
        select 1 from public.status_transitions
        where from_status_id = v_from and to_status_id = v_to
    ) then
        select name into v_from_name from public.order_statuses where id = v_from;
        raise exception 'Переход запрещён моделью: % → %', v_from_name, v_to_name;
    end if;

    update public.orders set status_id = v_to where id = p_order_id;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (p_order_id, v_to, p_changed_by, p_comment);

    return jsonb_build_object('ok', true, 'status', p_status_code, 'status_name', v_to_name);
end;
$$;

comment on function public.admin_set_status(integer, text, text, text) is
    'Смена статуса заказа только по разрешённым переходам статусной модели';

-- ----------------------------------------------------------------------------
-- 3. Признак оплаты
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_paid(p_order_id integer, p_is_paid boolean)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
    if not exists (select 1 from public.orders where id = p_order_id) then
        raise exception 'Заказ не найден';
    end if;

    update public.orders
       set is_paid = p_is_paid,
           paid_at = case when p_is_paid then coalesce(paid_at, now()) else null end
     where id = p_order_id;

    return jsonb_build_object('ok', true, 'is_paid', p_is_paid);
end;
$$;

comment on function public.admin_set_paid(integer, boolean) is
    'Отметка об оплате: признак is_paid и дата paid_at';
