-- ============================================================================
--  SISKU (черновик) — СКРИПТ 09: бандлы чтения — 9 конечных версий (консолидация v0.21.1)
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

-- Бандлы — один запрос на страницу (грабля №4/№6); сгенерированы из
-- конечного состояния каталога эталонной базы

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
with th as (
    /* пороги из site_content с безопасным CAST: только непустые строки
       из цифр (translate) ограниченной длины; иначе — дефолты (Д1/риск-лист) */
    select
        greatest(1, coalesce(
            (select case when translate(sc.value, '0123456789', '') = ''
                          and length(sc.value) between 1 and 6
                         then sc.value::integer end
               from public.site_content sc
              where sc.key = 'segments.vip_orders_min'), 5))  as vip_orders_min,
        greatest(0, coalesce(
            (select case when translate(sc.value, '0123456789', '') = ''
                          and length(sc.value) between 1 and 9
                         then sc.value::integer end
               from public.site_content sc
              where sc.key = 'segments.vip_sum_min'), 100000)) as vip_sum_min,
        greatest(1, coalesce(
            (select case when translate(sc.value, '0123456789', '') = ''
                          and length(sc.value) between 1 and 5
                         then sc.value::integer end
               from public.site_content sc
              where sc.key = 'segments.dormant_days'), 90))    as dormant_days
)
select jsonb_build_object(
    'clients', (select coalesce(jsonb_agg(c order by c.created_at desc, c.id desc), '[]'::jsonb)
                  from public.clients c),
    'stats',   (select coalesce(jsonb_agg(jsonb_build_object(
                    'client_id',   s.client_id,
                    'orders',      s.orders_cnt,
                    'sum',         s.sum_total,
                    'paid_sum',    s.sum_paid,
                    'first_order', s.first_order,
                    'last_order',  s.last_order,
                    'segment',     case
                                     when s.orders_cnt >= th.vip_orders_min
                                       or s.sum_total    >= th.vip_sum_min
                                       then 'vip'
                                     when s.orders_cnt >= 2 then 'repeat'
                                     else 'new'
                                   end,
                    'is_dormant',  coalesce(s.last_order < now()
                                            - make_interval(days => th.dormant_days),
                                           false)
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
                         group by o.client_id) s
                 cross join th),   -- агрегаты — в подзапросе (fix 42803, v2)
    'thresholds', (select jsonb_build_object(
                    'vip_orders_min', th.vip_orders_min,
                    'vip_sum_min',    th.vip_sum_min,
                    'dormant_days',   th.dormant_days)
                     from th)
);
$$;

comment on function public.draft_clients_bundle is 'v3 (волна v0.19.0, fp №7): v2 + сегменты клиентов сервером — segment (new/repeat/vip; приоритет VIP > repeat > new; пороги — site_content segments.*, безопасный CAST с fallback) и is_dormant (последний заказ старше segments.dormant_days — независимый признак, кросс-фильтр); в корне — thresholds; форма v2 сохранена (совместимость с clients.html v0.18.0)';

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
                     from public.return_reasons rr where rr.is_active),
    'badges',     (select coalesce(jsonb_agg(b order by b.sort_order, b.id), '[]'::jsonb)
                     from public.badges b where b.is_active),
    'product_badges', (select coalesce(jsonb_agg(pb order by pb.sort_order, pb.id), '[]'::jsonb)
                     from public.product_badges pb
                     join public.badges b on b.id = pb.badge_id and b.is_active)
);
$$;

comment on function public.draft_storefront_bundle is 'v3 (волна v0.21.0): + badges (активный справочник) и product_badges (назначения только активных бейджей) — витрина рендерит бейджи карточек по справочнику вместо хардкода «New по created_at» (fp №16, Д6); v2-ключи (волна v0.16.0 — return_reasons и пр.) без изменений; все данные витрины одним RPC — грабля №6';

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

-- ---------- draft_client_card_bundle ----------
CREATE OR REPLACE FUNCTION public.draft_client_card_bundle(p_client_id integer)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'client', (select jsonb_build_object(
                   'id',             c.id,
                   'full_name',      c.full_name,
                   'phone',          c.phone,
                   'email',          c.email,
                   'address',        c.address,
                   'note',           c.note,
                   'name_confirmed', c.name_confirmed,
                   'created_at',     c.created_at,
                   'updated_at',     c.updated_at)
                 from public.clients c
                where c.id = p_client_id),
    'names',  (select coalesce(jsonb_agg(jsonb_build_object(
                   'full_name',  h.full_name,
                   'source',     h.source,
                   'created_by', h.created_by,
                   'created_at', h.created_at)
                   order by h.created_at asc, h.id asc), '[]'::jsonb)
                 from public.client_name_history h
                where h.client_id = p_client_id),
    'contacts', (select coalesce(jsonb_agg(jsonb_build_object(
                   'type',       h.type,
                   'value',      h.value,
                   'action',     h.action,
                   'changed_by', h.changed_by,
                   'created_at', h.created_at)
                   order by h.created_at asc, h.id asc), '[]'::jsonb)
                 from public.client_contact_history h
                where h.client_id = p_client_id),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id',            o.id,
                   'created_at',    o.created_at,
                   'status_code',   s.code,
                   'status_name',   s.name,
                   'is_paid',       o.is_paid,
                   'total',         o.total,
                   'delivery_cost', o.delivery_cost,
                   'items', (select coalesce(jsonb_agg(jsonb_build_object(
                                'title_snapshot',   oi.title_snapshot,
                                'variant_snapshot', oi.variant_snapshot,
                                'quantity',         oi.quantity,
                                'price',            oi.price)
                                order by oi.id asc), '[]'::jsonb)
                               from public.order_items oi
                              where oi.order_id = o.id))
                   order by o.created_at desc, o.id desc), '[]'::jsonb)
                 from public.orders o
                 join public.order_statuses s on s.id = o.status_id
                where o.client_id = p_client_id)
);
$$;

comment on function public.draft_client_card_bundle is 'Черновик (волна v0.18.0, решение Д5): карточка клиента одним RPC — клиент, варианты имён, история контактов, все заказы с позициями и статусами (новые сверху); грабля №6 — один запрос на открытие карточки, без N+1';

-- ---------- draft_inventory_bundle ----------
CREATE OR REPLACE FUNCTION public.draft_inventory_bundle(p_session_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'sessions', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id',               s.id,
                    'scope',            s.scope,
                    'scope_categories', s.scope_categories,
                    'scope_names',      (select coalesce(jsonb_agg(c.name order by c.name), '[]'::jsonb)
                                          from public.categories c
                                         where s.scope = 'categories'
                                           and c.id::text in (select jsonb_array_elements_text(s.scope_categories))),
                    'plan_date',        s.plan_date,
                    'status',           s.status,
                    'participants',     s.participants,
                    'participant_names',(select coalesce(jsonb_agg(a.fio order by a.fio), '[]'::jsonb)
                                          from public.admin_users a
                                         where a.id::text in (select jsonb_array_elements_text(s.participants))),
                    'created_by',       s.created_by,
                    'started_at',       s.started_at,
                    'finished_at',      s.finished_at,
                    'created_at',       s.created_at,
                    'items_total',      (select count(*) from public.inventory_items ii
                                          where ii.session_id = s.id),
                    'items_counted',    (select count(*) from public.inventory_items ii
                                          where ii.session_id = s.id and ii.fact_qty is not null),
                    'discrepancies',    (select count(*) from public.inventory_items ii
                                          where ii.session_id = s.id and coalesce(ii.diff, 0) <> 0)
                 ) order by s.id desc), '[]'::jsonb)
                  from public.inventory_sessions s),
    'reasons',   (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', r.id, 'code', r.code, 'name', r.name,
                    'is_system', r.is_system, 'is_active', r.is_active,
                    'sort_order', r.sort_order
                 ) order by r.sort_order, r.id), '[]'::jsonb)
                  from public.writeoff_reasons r),
    'categories',(select coalesce(jsonb_agg(jsonb_build_object(
                    'id', c.id, 'name', c.name) order by c.name, c.id), '[]'::jsonb)
                  from public.categories c),
    'admins',    (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', a.id, 'fio', a.fio, 'role', a.role) order by a.fio, a.id), '[]'::jsonb)
                  from public.admin_users a
                 where a.is_active),
    'sheet',     case when p_session_id is null then null
                 else (select coalesce(jsonb_agg(jsonb_build_object(
                    'item_id',        ii.id,
                    'variant_id',     ii.variant_id,
                    'product_id',     pr.id,
                    'article',        pr.article,
                    'product',        pr.name,
                    'variant',        pv.label,
                    'system_qty',     ii.system_qty,
                    'reserved_qty',   ii.reserved_qty,
                    'quarantine_qty', ii.quarantine_qty,
                    'expected_qty',   ii.expected_qty,
                    'fact_qty',       ii.fact_qty,
                    'diff',           ii.diff,
                    'stock_now',      pv.stock,
                    'counted_by',     ii.counted_by,
                    'updated_at',     ii.updated_at
                 ) order by pr.name, pv.sort_order, pv.label, ii.id), '[]'::jsonb)
                  from public.inventory_items ii
                  join public.product_variants pv on pv.id = ii.variant_id
                  join public.products pr on pr.id = pv.product_id
                 where ii.session_id = p_session_id)
                 end
);
$$;

comment on function public.draft_inventory_bundle is 'Бандл панели «Инвентаризация» (волна v0.20.0, Д9 — грабля №6, один запрос): без p_session_id — сессии (с агрегатами листа: всего/посчитано/расхождений, ФИО участников, имена категорий) + справочник причин + категории + активные админы (форма создания); с p_session_id — дополнительно sheet: лист (snapshot system/reserved/quarantine/expected + fact/diff + stock_now + товар/вариант/артикул)';

-- ---------- draft_writeoffs_bundle ----------
CREATE OR REPLACE FUNCTION public.draft_writeoffs_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'writeoffs', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id',         w.id,
                    'created_at', w.created_at,
                    'variant_id', w.variant_id,
                    'product_id', pr.id,
                    'article',    pr.article,
                    'product',    pr.name,
                    'variant',    pv.label,
                    'price',      pr.price,          /* суммы — по текущей цене (Д8; в бою — исторические цены, fp №28) */
                    'qty',        w.qty,
                    'reason_id',  w.reason_id,
                    'reason',     coalesce(wr.name, '—'),
                    'reason_code', wr.code,
                    'session_id', w.session_id,
                    'comment',    w.comment,
                    'changed_by', w.changed_by
                 ) order by w.created_at desc, w.id desc), '[]'::jsonb)
                  from public.writeoffs w
                  join public.product_variants pv on pv.id = w.variant_id
                  join public.products pr on pr.id = pv.product_id
                  left join public.writeoff_reasons wr on wr.id = w.reason_id),
    'reasons',   (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', r.id, 'code', r.code, 'name', r.name,
                    'is_system', r.is_system, 'is_active', r.is_active,
                    'sort_order', r.sort_order
                 ) order by r.sort_order, r.id), '[]'::jsonb)
                  from public.writeoff_reasons r),
    'sessions',  (select coalesce(jsonb_agg(jsonb_build_object(
                    'id',            s.id,
                    'scope',         s.scope,
                    'plan_date',     s.plan_date,
                    'created_at',    s.created_at,
                    'started_at',    s.started_at,
                    'finished_at',   s.finished_at,
                    'writeoff_lines',(select count(*) from public.writeoffs w
                                       where w.session_id = s.id and w.qty < 0),
                    'writeoff_qty',  (select coalesce(sum(-w.qty), 0) from public.writeoffs w
                                       where w.session_id = s.id and w.qty < 0),
                    'surplus_lines', (select count(*) from public.writeoffs w
                                       where w.session_id = s.id and w.qty > 0),
                    'surplus_qty',   (select coalesce(sum(w.qty), 0) from public.writeoffs w
                                       where w.session_id = s.id and w.qty > 0)
                 ) order by s.id desc), '[]'::jsonb)
                  from public.inventory_sessions s
                 where s.status = 'done')
);
$$;

comment on function public.draft_writeoffs_bundle is 'Журнал списаний + статистика одним RPC (волна v0.20.0, Д8/Д9 — подвкладка «Статистика → Списания» и журнал панели «Инвентаризация»; лениво — паттерн draft_returns_bundle): writeoffs (товар/вариант/артикул/текущая цена для сумм, qty ±, причина, автор, комментарий, session_id) + reasons + проведённые сессии с итогами (строк/шт списаний и излишков); суммы — по текущей цене товара (в бою — по закупочной и цене продажи на момент инвентаризации, fp №28)';

-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = any (array['draft_reserved_map', 'draft_admin_bundle', 'draft_assembly_bundle', 'draft_clients_bundle', 'draft_storefront_bundle', 'draft_returns_bundle', 'draft_client_card_bundle', 'draft_inventory_bundle', 'draft_writeoffs_bundle']))            as bundles_9,   -- ждём 9
    (select obj_description(oid,'pg_proc') like 'v3%' from pg_proc where proname = 'draft_clients_bundle')    as clients_v3,   -- ждём t
    (select obj_description(oid,'pg_proc') like 'v3%' from pg_proc where proname = 'draft_storefront_bundle') as storefront_v3,-- ждём t
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public')                                            as funcs_total_29; -- ждём 29
-- Ожидаемая строка самопроверки (psql -At): 9|t|t|29
