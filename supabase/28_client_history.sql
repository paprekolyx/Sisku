-- ============================================================================
--  SISKU (черновик) — СКРИПТ 28: история клиента — варианты имён и контактов
-- ============================================================================
--  Волна v0.18.0 (09.10.2026) — «Карточка клиента» (fp №1, план развития
--  §3.2; правила владельца 05.10.2026, записка 8а):
--    (а) в карточке клиента — список вариантов имени, которые клиент сам
--        вводил при оформлении заказа, и правок администратора;
--    (б) историю изменения контактов вести так же, как историю имён;
--    (в) правило «админ изменил контакт → заказ на старые контакты создаёт
--        НОВОГО клиента» обеспечивается колоночной моделью clients
--        (phone_key/email_key уникальны: старые ключи перестают совпадать),
--        история фиксирует утрату силы контакта (решение Д1 09.10.2026:
--        отдельная таблица client_contacts НЕ создаётся).
--  RLS: включён, анонимных политик НЕТ — чтение и запись истории только
--  через SECURITY DEFINER функции скрипта 29 (draft_client_card_bundle,
--  admin_update_client, create_order v9). Паттерн: запись return_requests —
--  только через RPC (baseline 02). Счётчик политик не меняется (62).
--  ⚠ Backfill существующих клиентов — одноразовый с guard (культура
--  скриптов 25/27): повторный прогон — no-op.
--  Идемпотентен: create table if not exists. Порядок: после baseline 01–05,
--  09 и инкрементов 26–27. Применим к живой базе (инкремент — модель F21).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: скрипт должен выполняться в проекте Sisku
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.clients') is null then
        raise exception 'Скрипт 28: таблица public.clients не найдена — выбран не тот проект Supabase или не выполнен baseline 01';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Таблица вариантов имён
-- ----------------------------------------------------------------------------
create table if not exists public.client_name_history (
    id         serial primary key,
    client_id  integer not null references public.clients(id) on delete cascade,
    full_name  text not null,
    source     text not null default 'order'
               check (source in ('order', 'admin', 'merge', 'backfill')),
    created_by text not null default 'site',
    created_at timestamptz not null default now()
);

create index if not exists client_name_history_client_idx
    on public.client_name_history (client_id, created_at);

-- ----------------------------------------------------------------------------
-- 2. Таблица истории контактов
-- ----------------------------------------------------------------------------
create table if not exists public.client_contact_history (
    id         serial primary key,
    client_id  integer not null references public.clients(id) on delete cascade,
    type       text not null check (type in ('phone', 'email')),
    value      text,
    action     text not null default 'set'
               check (action in ('set', 'changed', 'offered', 'invalidated')),
    changed_by text not null default 'site',
    created_at timestamptz not null default now()
);

create index if not exists client_contact_history_client_idx
    on public.client_contact_history (client_id, created_at);

-- ----------------------------------------------------------------------------
-- 3. RLS: включён, анонимных политик нет (доступ только через RPC скрипта 29)
-- ----------------------------------------------------------------------------
alter table public.client_name_history enable row level security;
alter table public.client_contact_history enable row level security;

-- ----------------------------------------------------------------------------
-- 4. Комментарии
-- ----------------------------------------------------------------------------
comment on table public.client_name_history is
    'Варианты имён клиента (волна v0.18.0, fp №1): каждое имя из заказов и каждая правка администратора; правило владельца 05.10.2026 — в карточке видны варианты, которые клиент вводил сам; прямого доступа нет — только RPC';
comment on column public.client_name_history.source is
    'Источник варианта: order — из заказа, admin — правка карточки, merge — слияние, backfill — исходные данные';
comment on column public.client_name_history.created_by is
    'Кто записал: site (заказ с витрины), admin (карточка клиента), backfill (скрипт 28)';
comment on table public.client_contact_history is
    'История изменения телефонов и e-mail клиента (волна v0.18.0): ведётся так же, как история имён (правило владельца 05.10.2026); прямого доступа нет — только RPC';
comment on column public.client_contact_history.action is
    'set — указан, changed — изменён администратором, offered — предложен в заказе (не принят — решение Д3), invalidated — утратил силу (заменён администратором)';
comment on column public.client_contact_history.changed_by is
    'Кто записал: site (заказ с витрины), admin (карточка клиента), backfill (скрипт 28)';

-- ----------------------------------------------------------------------------
-- 5. Backfill существующих клиентов (⚠ одноразовый, guard — таблицы пусты;
--    phone и email — ОДНИМ запросом, чтобы guard не сработал между вставками)
-- ----------------------------------------------------------------------------
insert into public.client_name_history (client_id, full_name, source, created_by, created_at)
select c.id, c.full_name, 'backfill', 'backfill', c.created_at
  from public.clients c
 where not exists (select 1 from public.client_name_history);

insert into public.client_contact_history (client_id, type, value, action, changed_by, created_at)
select x.id, x.type, x.value, 'set', 'backfill', x.created_at
  from (select c.id, 'phone'::text as type, c.phone as value, c.created_at
          from public.clients c
         where c.phone is not null
        union all
        select c.id, 'email'::text, c.email, c.created_at
          from public.clients c
         where c.email is not null) x
 where not exists (select 1 from public.client_contact_history);

-- ----------------------------------------------------------------------------
-- 6. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select to_regclass('public.client_name_history') is not null)    as name_table,     -- ждём t
    (select to_regclass('public.client_contact_history') is not null) as contact_table,  -- ждём t
    (select relrowsecurity from pg_class
      where oid = 'public.client_name_history'::regclass)             as name_rls,       -- ждём t
    (select relrowsecurity from pg_class
      where oid = 'public.client_contact_history'::regclass)          as contact_rls,    -- ждём t
    (select (select count(*) from public.client_name_history)
          >= (select count(*) from public.clients))                   as backfill_ok,    -- ждём t
    (select (select count(*) from pg_policies
              where tablename in ('client_name_history',
                                  'client_contact_history')) = 0)     as no_anon_policies; -- ждём t
-- Ожидаемая строка самопроверки (psql -At): t|t|t|t|t|t
