-- ============================================================================
--  SISKU (черновик) — СКРИПТ 35: кросс-сегменты клиентов (волна v0.22.0)
-- ============================================================================
--  Цель: «Статистика → Клиенты» — независимые флаги сегментов (записка 6
--  приёмки v0.21.0, Д4): draft_clients_bundle v4 добавляет в строки stats
--  is_new (заказов <= 1), is_repeat (заказов >= 2), is_vip (пороги
--  site_content segments.*, БЕЗ приоритета VIP > repeat); поле segment
--  сохраняется (совместимость и CSV — приоритет vip > repeat > new);
--  is_dormant, thresholds и форма v2/v3 — без изменений. Уснувший VIP
--  виден в обоих сегментах; фильтр «Сегмент» на фронтенде — мультивыбор,
--  логика «И» (соответствие ВСЕМ выбранным признакам).
--  Волна: v0.22.0 (MINOR). Порядок: baseline 01–05, 09 (ревизия 2) → 34 → 35.
--  Живая база (F21): только инкременты; скрипт идемпотентен
--  (create or replace function), повторный прогон — no-op.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regprocedure('public.draft_clients_bundle()') is null then
        raise exception 'Скрипт 35: функция draft_clients_bundle не найдена — сначала выполните baseline 01–05, 09 (ревизия 2)';
    end if;
    if to_regprocedure('public.draft_attrs_bundle()') is null then
        raise exception 'Скрипт 35: функция draft_attrs_bundle не найдена — сначала выполните скрипт 34 (порядок строгий: 34 → 35)';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. draft_clients_bundle → v4 (независимые флаги сегментов)
-- ----------------------------------------------------------------------------
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
                    'is_new',      s.orders_cnt <= 1,
                    'is_repeat',   s.orders_cnt >= 2,
                    'is_vip',      s.orders_cnt >= th.vip_orders_min
                                    or s.sum_total >= th.vip_sum_min,
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

comment on function public.draft_clients_bundle is 'v4 (волна v0.22.0, записка 6 приёмки v0.21.0 / Д4): v3 + независимые кросс-флаги сегментов в строках stats — is_new (заказов <= 1), is_repeat (заказов >= 2), is_vip (пороги site_content segments.*, без приоритета VIP > repeat); поле segment сохранено для совместимости и CSV (приоритет vip > repeat > new); is_dormant — прежний независимый признак; thresholds и форма v2/v3 без изменений; фронтенд: фильтр «Сегмент» — мультивыбор (логика «И»), KPI — по флагам (пересечения допустимы); дополнение к fp №7';

-- ----------------------------------------------------------------------------
-- Самопроверка (точные ожидаемые значения)
-- ----------------------------------------------------------------------------
select
    (select obj_description(oid,'pg_proc') like 'v4%' from pg_proc
      where proname = 'draft_clients_bundle')    as clients_v4,    -- ждём t
    (select obj_description(oid,'pg_proc') like 'v4%' from pg_proc
      where proname = 'draft_storefront_bundle') as storefront_v4; -- ждём t (регресс скрипта 34)
-- Ожидаемая строка самопроверки (psql -At): t|t
-- Контроль на живой базе (REST, update-v0220.md §4 п.4): контрольный клиент
-- (11 заказов) — is_vip = true И is_repeat = true (пересечение сегментов).
