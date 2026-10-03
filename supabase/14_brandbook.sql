-- ============================================================================
--  SISKU (черновик) — СКРИПТ 14: конструктор брендбука + частичные комплекты
-- ============================================================================
--  1. Таблица brand_colors: живые значения цветов витрины по темам
--     (theme: light / dark) и глобальная типографика (theme: global).
--     ОТДЕЛЬНАЯ таблица, не site_content — чтобы не смешивать тексты и стиль.
--     Витрина читает её при загрузке и подставляет в CSS-переменные до
--     отрисовку карточек; админка правит значения и хранит шаблоны.
--  2. Таблица brand_templates: именованные шаблоны палитры
--     (название + комментарий + все значения обеих тем одним jsonb).
--  3. create_order v4: скидка комплекта применяется к тем позициям лука,
--     которые фактически лежат в корзине (полнота больше не обязательна —
--     покупатель может добавить комплект частично после подтверждения).
--  4. look_items.variant_id уже nullable: комплект может включать товар
--     «целиком» (вся размерная сетка) — вариант выбирает покупатель.
--  Идемпотентен.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Живые цвета и типографика витрины
-- ----------------------------------------------------------------------------
create table if not exists public.brand_colors (
    id     serial primary key,
    theme  text not null check (theme in ('light', 'dark', 'global')),
    key    text not null,
    value  text not null,
    unique (theme, key)
);
comment on table public.brand_colors is
    'Значения дизайн-токенов витрины: light/dark — цвета, global — типографика';

alter table public.brand_colors enable row level security;

drop policy if exists draft_anon_read_brand_colors on public.brand_colors;
create policy draft_anon_read_brand_colors on public.brand_colors
    for select to anon, authenticated using (true);
drop policy if exists draft_anon_write_brand_colors on public.brand_colors;
create policy draft_anon_write_brand_colors on public.brand_colors
    for insert to anon, authenticated with check (true);
drop policy if exists draft_anon_update_brand_colors on public.brand_colors;
create policy draft_anon_update_brand_colors on public.brand_colors
    for update to anon, authenticated using (true) with check (true);
drop policy if exists draft_anon_delete_brand_colors on public.brand_colors;
create policy draft_anon_delete_brand_colors on public.brand_colors
    for delete to anon, authenticated using (true);

-- стартовые значения = текущие токены стилей (ничего визуально не меняют)
insert into public.brand_colors (theme, key, value) values
    ('light', 'bg',       '#FAF7F2'),
    ('light', 'surface',  '#FFFFFF'),
    ('light', 'card',     '#FFFFFF'),
    ('light', 'text',     '#1A1A1E'),
    ('light', 'muted',    '#6F6A60'),
    ('light', 'accent',   '#7A5C2E'),
    ('light', 'line',     '#E5E0D6'),
    ('light', 'btn_bg',   '#1A1A1E'),
    ('light', 'btn_text', '#FAF7F2'),
    ('dark',  'bg',       '#0D0D10'),
    ('dark',  'surface',  '#16161B'),
    ('dark',  'card',     '#1D1D24'),
    ('dark',  'text',     '#F2EEE4'),
    ('dark',  'muted',    '#A79FB0'),
    ('dark',  'accent',   '#C9A96A'),
    ('dark',  'line',     '#2A2A33'),
    ('dark',  'btn_bg',   '#C9A96A'),
    ('dark',  'btn_text', '#0D0D10'),
    ('global', 'typo_base',  '16'),    /* px основного текста */
    ('global', 'typo_scale', '100')    /* % масштаба заголовков */
on conflict (theme, key) do nothing;

-- ----------------------------------------------------------------------------
-- 2. Шаблоны палитр
-- ----------------------------------------------------------------------------
create table if not exists public.brand_templates (
    id         serial primary key,
    name       text not null,
    comment    text,
    colors     jsonb not null,          -- {light:{bg:…}, dark:{bg:…}, global:{typo_base:…}}
    created_at timestamptz not null default now()
);
comment on table public.brand_templates is
    'Сохранённые наборы цветов обеих тем: применить / удалить в один клик';

alter table public.brand_templates enable row level security;

drop policy if exists draft_anon_read_brand_templates on public.brand_templates;
create policy draft_anon_read_brand_templates on public.brand_templates
    for select to anon, authenticated using (true);
drop policy if exists draft_anon_write_brand_templates on public.brand_templates;
create policy draft_anon_write_brand_templates on public.brand_templates
    for insert to anon, authenticated with check (true);
drop policy if exists draft_anon_update_brand_templates on public.brand_templates;
create policy draft_anon_update_brand_templates on public.brand_templates
    for update to anon, authenticated using (true) with check (true);
drop policy if exists draft_anon_delete_brand_templates on public.brand_templates;
create policy draft_anon_delete_brand_templates on public.brand_templates
    for delete to anon, authenticated using (true);

-- ----------------------------------------------------------------------------
-- 3. create_order v4: скидка комплекта по фактическому составу корзины
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
-- 4. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.brand_colors) as color_rows,          -- ожидаем 20
    (select count(*) from pg_policies
      where tablename in ('brand_colors', 'brand_templates')
        and policyname like 'draft_anon_%') as brand_policies;        -- ожидаем 8
