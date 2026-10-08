-- ============================================================================
--  SISKU (черновик) — СКРИПТ 09: бандлы чтения (6) — конечные версии на v0.16.0
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE (волна v0.17.0, 07.10.2026): состояние базы на
--  v0.16.0-draft одним скриптом. Заменяет исторические скрипты 09, 13 (draft_reserved_map v1), 15 (admin/clients v2), 16 (storefront v1, reserved_map v2), 22 (storefront v2, returns), 23 (assembly v2).
--  Исторические версии (включая промежуточные версии функций) — замороженный
--  архив supabase/archive/sql-01-25-v0160.md и git-история; номера удалённых
--  скриптов не переиспользуются (SQL-регламент).
--  Идемпотентен: create or replace function — тела конечных версий (v0.16.0).
--  Порядок для НОВОГО стенда: 01 → 02 → 03 → 04 → 05 → 09 → 26 → 27.
--  ⚠ НА ЖИВОЙ БАЗЕ (контент отредактирован владельцем) baseline НЕ
--  перезапускать — модель F21: живая база получает только инкременты ≥ 26.
-- ============================================================================


-- ---------- draft_reserved_map ----------

CREATE OR REPLACE FUNCTION public.draft_reserved_map()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select coalesce(jsonb_agg(jsonb_build_object('variant_id', t.variant_id, 'reserved', t.qty)), '[]'::jsonb)
from (
    select i.variant_id, sum(i.quantity) as qty
    from public.order_items i
    join public.orders o on o.id = i.order_id
    join public.order_statuses s on s.id = o.status_id
    -- открытые статусы (модель v0.2.0+, без «Оплачен» — это признак is_paid):
    -- новый, подтверждённый, собирается. 'paid' удалён из списка (fix F18).
    where s.code in ('new', 'confirmed', 'packing')
      and i.variant_id is not null
    group by i.variant_id
) t;
$$;


comment on function public.draft_reserved_map is 'v2: сколько единиц варианта зарезервировано открытыми заказами (new/confirmed/packing); fix F18 — мёртвый статус paid убран';


-- ---------- draft_admin_bundle ----------

CREATE OR REPLACE FUNCTION public.draft_admin_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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


comment on function public.draft_admin_bundle is 'Черновик: весь набор данных админки одним запросом; v2 — добавлен блок promos (статистика акций)';


-- ---------- draft_assembly_bundle ----------

CREATE OR REPLACE FUNCTION public.draft_assembly_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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


comment on function public.draft_assembly_bundle is 'v2 (волна v0.16.0): заказы в сборке + позиции + остатки склада с карантином (quarantine_qty) одним запросом';


-- ---------- draft_clients_bundle ----------

CREATE OR REPLACE FUNCTION public.draft_clients_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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


comment on function public.draft_clients_bundle is 'Черновик: клиенты + агрегаты их заказов (кол-во, суммы, даты) одним запросом; v2 — двухступенчатая агрегация статистики (fix 42803)';


-- ---------- draft_storefront_bundle ----------

CREATE OR REPLACE FUNCTION public.draft_storefront_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'brands',     (select coalesce(jsonb_agg(b order by b.name), '[]'::jsonb)
                     from public.brands b where b.is_active),
    'categories', (select coalesce(jsonb_agg(c order by c.id), '[]'::jsonb)
                     from public.categories c),
    'products',   (select coalesce(jsonb_agg(pr order by pr.created_at desc, pr.id desc), '[]'::jsonb)
                     from public.products pr where pr.is_active),
    'variants',   (select coalesce(jsonb_agg(v order by v.sort_order, v.id), '[]'::jsonb)
                     from public.product_variants v),
    'content',    (select coalesce(jsonb_agg(jsonb_build_object('key', sc.key, 'value', sc.value)), '[]'::jsonb)
                     from public.site_content sc),
    'payments',   (select coalesce(jsonb_agg(m order by m.id), '[]'::jsonb)
                     from public.payment_methods m where m.is_active),
    'deliveries', (select coalesce(jsonb_agg(m order by m.id), '[]'::jsonb)
                     from public.delivery_methods m where m.is_active),
    'looks',      (select coalesce(jsonb_agg(l order by l.created_at desc, l.id desc), '[]'::jsonb)
                     from public.looks l where l.is_active),
    'look_items', (select coalesce(jsonb_agg(li order by li.sort_order, li.id), '[]'::jsonb)
                     from public.look_items li),
    'brand',      (select coalesce(jsonb_agg(jsonb_build_object(
                       'theme', bc.theme, 'key', bc.key, 'value', bc.value)), '[]'::jsonb)
                     from public.brand_colors bc),
    'return_reasons', (select coalesce(jsonb_agg(rr order by rr.sort_order, rr.id), '[]'::jsonb)
                     from public.return_reasons rr where rr.is_active)
);
$$;


comment on function public.draft_storefront_bundle is 'v2 (волна v0.16.0): все данные витрины одним RPC + return_reasons (активные причины возврата для формы заявки) — fix F27, прототип боевого GET /api/storefront';


-- ---------- draft_returns_bundle ----------

CREATE OR REPLACE FUNCTION public.draft_returns_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'requests', (select coalesce(jsonb_agg(r order by r.created_at desc, r.id desc), '[]'::jsonb)
                   from public.return_requests r),
    'reasons',  (select coalesce(jsonb_agg(rr order by rr.sort_order, rr.id), '[]'::jsonb)
                   from public.return_reasons rr),
    'content',  (select coalesce(jsonb_agg(jsonb_build_object('key', sc.key, 'value', sc.value)), '[]'::jsonb)
                   from public.site_content sc
                  where sc.key like 'returns.%')
);
$$;


comment on function public.draft_returns_bundle is 'Черновик: заявки на возврат + причины + тексты returns.* одним RPC (подвкладка «Заказы → Возвраты» и «Статистика → Возвраты»; заказы и статусы — из draft_admin_bundle)';


-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public')                                       as functions_total,   -- ждём 18
    (select count(*) from pg_proc where proname in
      ('draft_admin_bundle','draft_assembly_bundle','draft_clients_bundle',
       'draft_storefront_bundle','draft_reserved_map',
       'draft_returns_bundle'))                                         as bundles_ok,        -- ждём 6
    (select prosrc like '%return_reasons%' from pg_proc
      where proname = 'draft_storefront_bundle')                        as storefront_v2,     -- ждём t
    (select prosrc like '%quarantine_qty%' from pg_proc
      where proname = 'draft_assembly_bundle')                          as assembly_v2,       -- ждём t
    (select prosrc like '%promos%' from pg_proc
      where proname = 'draft_admin_bundle')                             as admin_bundle_v2;   -- ждём t
