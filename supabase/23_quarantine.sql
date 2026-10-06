-- ============================================================================
--  SISKU (черновик) — СКРИПТ 23: карантин возвращённых остатков (волна
--  v0.16.0; фикс F51 ревью v0.13.1 — замена авто-возврата остатков в продажу)
-- ============================================================================
--  СХЕМА УТВЕРЖДЕНА АНАЛИТИКОМ 06.10.2026 — ВАРИАНТ (а) СЧЁТЧИК:
--    • `product_variants.quarantine_qty` (CHECK ≥ 0) — сколько единиц
--      варианта вернулось и ТРЕБУЕТ ОСМОТРА. Доступный остаток витрины —
--      `stock` (карантин в него не входит: при «Возврате» единицы НЕ
--      возвращаются в продажу);
--    • `admin_set_status` v4: при переходе заказа в «Возврат» авто-возврат
--      остатка в `stock` ОТКЛЮЧЁН — единицы уходят в `quarantine_qty`.
--      «Отменён» — без изменений (остатки возвращаются в `stock`, как с
--      v0.10.0). Зарезервированные остатки (draft_reserved_map v2, открытые
--      статусы new/confirmed/packing) не затрагиваются — «Возврат» возможен
--      только из shipped/delivered, где резерва уже нет;
--    • обратный переход из «Возврата» моделью заказов не разрешён (returned —
--      финальный статус) — зеркальная логика не нужна; если модель изменится,
--      править v4 по тому же принципу;
--    • RPC осмотра `admin_resolve_quarantine(p_variant_id, p_qty, p_action,
--      p_changed_by)`: «вернуть в продажу» (restock: карантин → stock) или
--      «списать» (writeoff: единицы убираются из карантина без возврата
--      в stock). Осмотр — из карточки товара («Магазин → Товары»);
--      FOR UPDATE на строке варианта, qty ≤ quarantine_qty.
--
--  Складские ДВИЖЕНИЯ карантина (журнал, партии, частичные осмотры с
--  историей) — вариант (б), fp №3b, приоритет №14 черновика (волна-кандидат
--  v0.28.0): счётчик — сознательно простая схема макета.
--
--  Также: `draft_assembly_bundle` v2 — в остатках склада появляется
--  quarantine_qty (экран «Сборка» показывает карантин).
--
--  Скрипт идемпотентен: add column if not exists, констрейнт — только если
--  его ещё нет, create or replace function.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: убеждаемся, что мы в проекте черновика Sisku, а не в учебном
--    (правило 6 supabase/README.md).
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.product_variants') is null
       or to_regclass('public.orders') is null
       or to_regclass('public.order_status_history') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (product_variants / orders / order_status_history). Проверьте переключатель проектов Supabase слева вверху: нужен проект sisku-draft, а не учебный.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Счётчик карантина
-- ----------------------------------------------------------------------------
alter table public.product_variants
    add column if not exists quarantine_qty integer not null default 0;

comment on column public.product_variants.quarantine_qty is
    'Карантин (волна v0.16.0, фикс F51): единицы, вернувшиеся по заявке на возврат и требующие осмотра. В доступный остаток витрины (stock) НЕ входит; осмотр — admin_resolve_quarantine («вернуть в продажу» / «списать»); складские движения — fp №3b (v0.28.0)';

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'product_variants_quarantine_nonneg'
          and conrelid = 'public.product_variants'::regclass
    ) then
        alter table public.product_variants
            add constraint product_variants_quarantine_nonneg check (quarantine_qty >= 0);
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 2. admin_set_status v4: «Возврат» — остатки в карантин, «Отменён» — в stock
--    (v3, скрипт 16: FOR UPDATE на строке заказа сохранён — фикс F01)
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

comment on function public.admin_set_status(integer, text, text, text) is
    'v4 (волна v0.16.0, фикс F51): смена статуса с проверкой status_transitions и FOR UPDATE (fix F01); «Отменён» — остатки в stock, «Возврат» — в карантин quarantine_qty (требует осмотра, admin_resolve_quarantine)';

-- ----------------------------------------------------------------------------
-- 3. Осмотр карантина: вернуть в продажу / списать
-- ----------------------------------------------------------------------------
create or replace function public.admin_resolve_quarantine(
    p_variant_id integer,
    p_qty        integer,
    p_action     text,
    p_changed_by text default 'admin'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
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

comment on function public.admin_resolve_quarantine(integer, integer, text, text) is
    'Осмотр карантина (волна v0.16.0): restock — вернуть в продажу (карантин → stock), writeoff — списать (убрать из карантина без возврата в stock); FOR UPDATE на варианте, qty ≤ quarantine_qty; журнал движений — fp №3b (v0.28.0)';

-- ----------------------------------------------------------------------------
-- 4. draft_assembly_bundle v2: остатки склада вместе с карантином
-- ----------------------------------------------------------------------------
create or replace function public.draft_assembly_bundle()
returns jsonb
language sql security definer set search_path = public
as $$
select jsonb_build_object(
    'orders', (select coalesce(jsonb_agg(o order by o.created_at), '[]'::jsonb)
                 from public.orders o
                where o.status_id = (select id from public.order_statuses where code = 'packing')),
    'items',  (select coalesce(jsonb_agg(i), '[]'::jsonb)
                 from public.order_items i
                where i.order_id in (select o.id from public.orders o
                                      where o.status_id = (select id from public.order_statuses where code = 'packing'))),
    'stock',  (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', v.id, 'stock', v.stock, 'quarantine_qty', v.quarantine_qty)), '[]'::jsonb)
                 from public.product_variants v)
);
$$;

comment on function public.draft_assembly_bundle() is
    'v2 (волна v0.16.0): заказы в сборке + позиции + остатки склада с карантином (quarantine_qty) одним запросом';

-- ----------------------------------------------------------------------------
-- 5. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'product_variants'
        and column_name = 'quarantine_qty')                           as column_ok,        -- ждём 1
    (select count(*) from pg_constraint
      where conname = 'product_variants_quarantine_nonneg'
        and conrelid = 'public.product_variants'::regclass)           as constraint_ok,    -- ждём 1
    (select prosrc like '%quarantine_qty = quarantine_qty + v_item.quantity%'
       from pg_proc where proname = 'admin_set_status')               as set_status_v4,    -- ждём t
    (select position('set stock = stock + v_item.quantity' in prosrc)
          < position('quarantine_qty = quarantine_qty + v_item.quantity' in prosrc)
       from pg_proc where proname = 'admin_set_status')               as cancel_branch_first, -- ждём t (возврат в stock — только в ветке «Отменён», до ветки «Возврат»)
    (select count(*) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_resolve_quarantine') as resolve_fn, -- ждём 1
    (select count(*) from public.product_variants v
      where v.quarantine_qty >= 0)                                    as variants_with_column, -- ждём = числу вариантов (колонка есть, CHECK работает)
    (select prosrc like '%quarantine_qty%' from pg_proc
      where proname = 'draft_assembly_bundle')                        as assembly_v2;      -- ждём t
