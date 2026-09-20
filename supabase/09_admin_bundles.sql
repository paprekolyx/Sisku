-- ============================================================================
--  SISKU (черновик) — СКРИПТ 9: быстрые сборки данных + удаление пользователей
-- ============================================================================
--  1. draft_admin_bundle() — ОДИН запрос вместо семи для админки заказов
--     и статистики (orders, order_items, order_statuses, status_transitions,
--     payment_methods, delivery_methods, order_status_history одним jsonb).
--     Лечит долгую загрузку: меньше обращений к пулу соединений Supabase,
--     один round-trip вместо очереди запросов.
--  2. draft_assembly_bundle() — один запрос для экрана «Сборка»
--     (заказы в сборке + их позиции + остатки склада).
--  3. Политика DELETE для admin_users — функция удаления администратора
--     на странице «Пользователи» (черновик: anon, как и остальные операции).
--  Скрипт идемпотентен.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Сборка для админки заказов и статистики
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
                      from public.order_status_history h)
);
$$;

comment on function public.draft_admin_bundle() is
    'Черновик: весь набор данных админки одним запросом (борьба с долгой загрузкой)';

-- ----------------------------------------------------------------------------
-- 2. Сборка для экрана «Сборка»
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
    'stock',  (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'stock', v.stock)), '[]'::jsonb)
                 from public.product_variants v)
);
$$;

comment on function public.draft_assembly_bundle() is
    'Черновик: заказы в сборке + позиции + остатки одним запросом';

-- ----------------------------------------------------------------------------
-- 3. Удаление пользователей (черновик)
-- ----------------------------------------------------------------------------
drop policy if exists draft_anon_delete_admin_users on public.admin_users;
create policy draft_anon_delete_admin_users on public.admin_users
    for delete to anon, authenticated using (true);

-- ----------------------------------------------------------------------------
-- 4. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from jsonb_array_elements(draft_admin_bundle()->'statuses'))   as statuses_in_bundle,
    (select count(*) from jsonb_array_elements(draft_assembly_bundle()->'stock'))   as stock_rows;
