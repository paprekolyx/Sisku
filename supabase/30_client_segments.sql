-- ============================================================================
--  SISKU (черновик) — СКРИПТ 30: сегменты клиентов (CRM-light)
-- ============================================================================
--  Волна v0.19.0 (09.10.2026) — «Сегменты клиентов» (fp №7, план развития
--  §3.3; решение аналитика Д1/Д2 от 09.10.2026):
--    (1) пороги сегментов — ключи site_content `segments.*` (без новой
--        таблицы; редактируются из админки — «Статистика → Клиенты»,
--        пожелание владельца 05.10.2026; значения по умолчанию — до ответа
--        владельца на вопрос 5 универсального чек-листа);
--    (2) draft_clients_bundle v3 — сегменты считает СЕРВЕР: 'new' (1 заказ),
--        'repeat' (2+), 'vip' (заказов >= vip_orders_min ИЛИ сумма >=
--        vip_sum_min; приоритет VIP > repeat > new) + независимый признак
--        is_dormant (последний заказ старше dormant_days) — кросс-фильтр:
--        «уснувший VIP» виден и в VIP, и в «уснули» (решение Д2);
--    (3) форма бандла v2 сохранена (clients + stats) — обратно совместима
--        с clients.html/clients.js волны v0.18.0; добавлены поля segment,
--        is_dormant в stats и блок thresholds в корень ответа;
--    (4) безопасный CAST порогов: value — текст; мусор/пусто — fallback на
--        дефолты (бандл не падает); якоря регэкспов не используются —
--        только translate() (регламент «одиночных долларов нет», правило 4).
--  RLS/политики/таблицы — без изменений (site_content: чтение публично,
--  draft-CRUD — осознанная граница черновика, baseline 02; SECURITY.md).
--  Идемпотентен: on conflict do nothing + create or replace. Порядок: после
--  baseline 01–05, 09 и инкрементов 26–29. Применим к живой базе (модель
--  F21): посев добавляет только отсутствующие ключи.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: скрипт должен выполняться в проекте Sisku
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.site_content') is null
       or to_regclass('public.clients') is null then
        raise exception 'Скрипт 30: таблицы site_content/clients не найдены — выбран не тот проект Supabase или не выполнен baseline 01';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Пороги сегментов — ключи site_content (вставка только отсутствующих —
--    культура F21; значения по умолчанию: VIP — 5 заказов или 100000 руб.,
--    «уснул» — 90 дней; владелец скорректирует при приёмке — вопрос 5
--    универсального чек-листа)
-- ----------------------------------------------------------------------------
insert into public.site_content (key, value, description) values
    ('segments.vip_orders_min', '5',
     'Порог VIP-сегмента: заказов не менее («Статистика → Клиенты»)'),
    ('segments.vip_sum_min', '100000',
     'Порог VIP-сегмента: сумма заказов не менее, руб. («Статистика → Клиенты»)'),
    ('segments.dormant_days', '90',
     'Критерий «уснул»: дней без заказов («Статистика → Клиенты»)')
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- 2. draft_clients_bundle v3 (база — v2, baseline 09: двухступенчатая
--    агрегация статистики, fix 42803 — сохранена)
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

-- ----------------------------------------------------------------------------
-- 3. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.site_content
      where key like 'segments.%') = 3                             as seg_keys_3,      -- ждём t
    (select count(*) from public.site_content) >= 73               as keys_ge_73,      -- ждём t
    (select prosrc like '%is_dormant%' from pg_proc
      where proname = 'draft_clients_bundle')                      as v3_dormant,      -- ждём t
    (select prosrc like '%thresholds%' from pg_proc
      where proname = 'draft_clients_bundle')                      as v3_thresholds,   -- ждём t
    (select obj_description(oid, 'pg_proc') like 'v3%' from pg_proc
      where proname = 'draft_clients_bundle')                      as comment_v3,      -- ждём t
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public') = 20                             as func_count_20;   -- ждём t
-- Ожидаемая строка самопроверки (psql -At): t|t|t|t|t|t
