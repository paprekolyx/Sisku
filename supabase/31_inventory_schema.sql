-- ============================================================================
--  SISKU (черновик) — СКРИПТ 31: инвентаризация и списания — схема
-- ============================================================================
--  Волна v0.20.0 (10.10.2026) — «Инвентаризация и списания» (fp №9, план
--  развития §3.4; решения аналитика Д1–Д12 от 10.10.2026; ответы владельца
--  7.1–7.3, опросник ред. 1.6):
--    (1) 4 таблицы: `writeoff_reasons` (справочник причин списаний — паттерн
--        `return_reasons` + `code`/`is_system`), `inventory_sessions` (сессии:
--        область, статус, участники, план-дата), `inventory_items` (лист:
--        snapshot остатков + факт + расхождение), `writeoffs` (журнал
--        списаний/излишков — проектируется под будущее объединение с движениями
--        карантина, fp №3b — единый журнал склада v0.29.0, ответ 7.13);
--    (2) посев справочника — 5 причин БЕЗ «Уценки» (ответ 7.2: уценка — вид
--        акции, а не уменьшение количества); `shortage`/`surplus` — системные
--        (is_system): используются RPC завершения сессии, не деактивируются;
--    (3) ГЕЙТ АН-21 ЗАКРЫТ (10.10.2026) — вариант (б) «предупреждение
--        с проведением»: CHECK `stock >= 0` у `product_variants` СНИМАЕТСЯ —
--        минус/ноль остатка становятся допустимым состоянием после проведения
--        инвентаризации (осознанное решение владельца/аналитика; юрист-
--        подтверждение — блокер M4). Защита витрины сохраняется: условное
--        списание `create_order` (`where stock >= qty` → «Недостаточно
--        остатка») — заказ с нулевым/минусовым остатком создать нельзя;
--        сборка — минус/ноль виден сборщику (подсветка, assembly.js);
--    (4) статусная модель сессии (Д2): planned → in_progress → done
--        + cancelled (отмена из любого статуса, кроме done); переходы — ТОЛЬКО
--        ручные (авто-старта по plan_date нет); параллельные in_progress-
--        сессии разрешены (ответ 7.3(а) — guard «одна идущая» НЕ делается).
--  RLS (Д10): включён на всех 4 таблицах; `writeoff_reasons` — anon-чтение
--  + draft-insert/update (удаление — только деактивацией, паттерн
--  `return_reasons` baseline 02) = +3 политики (62 → 65); сессии/лист/журнал —
--  БЕЗ анонимных политик: запись только через RPC скрипта 32, чтение — через
--  бандлы (паттерн истории клиента v0.18.0).
--  Идемпотентен: create table if not exists + drop/create policy + on conflict
--  do nothing + drop constraint if exists. Порядок: после baseline 01–05, 09
--  и инкрементов 26–30. Применим к живой базе (модель F21): посев добавляет
--  только отсутствующие причины; повторный прогон — no-op.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: скрипт должен выполняться в проекте Sisku
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.product_variants') is null
       or to_regclass('public.admin_users') is null
       or to_regclass('public.categories') is null
       or to_regclass('public.products') is null then
        raise exception 'Скрипт 31: таблицы product_variants/admin_users/categories/products не найдены — выбран не тот проект Supabase или не выполнен baseline 01';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Справочник причин списаний (Д1/Д11; паттерн return_reasons + code/
--    is_system как у будущих бейджей fp №16)
-- ----------------------------------------------------------------------------
create table if not exists public.writeoff_reasons (
    id         serial primary key,
    code       text not null unique,       -- defect, sample, shortage…
    name       text not null,
    is_system  boolean not null default false,  -- системные не деактивируются
    is_active  boolean not null default true,
    sort_order integer not null default 1
);

-- ----------------------------------------------------------------------------
-- 2. Сессии инвентаризации (Д2/Д3)
-- ----------------------------------------------------------------------------
create table if not exists public.inventory_sessions (
    id               serial primary key,
    scope            text not null check (scope in ('all', 'categories')),
    scope_categories jsonb not null default '[]'::jsonb,   -- id категорий при scope='categories'
    plan_date        date,                                 -- план-дата (nullable)
    status           text not null default 'planned'
                     check (status in ('planned', 'in_progress', 'done', 'cancelled')),
    participants     jsonb not null default '[]'::jsonb,   -- id из admin_users
    created_by       text not null default 'admin',        -- текстовый автор (до M2)
    started_at       timestamptz,
    finished_at      timestamptz,                          -- завершение или отмена
    created_at       timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 3. Лист инвентаризации (Д4): snapshot на момент создания/старта сессии —
--    «ожидаемо физически» = stock + reserved + quarantine (всё физически
--    присутствует на складе); unique (session_id, variant_id) — upsert листа
-- ----------------------------------------------------------------------------
create table if not exists public.inventory_items (
    id             serial primary key,
    session_id     integer not null references public.inventory_sessions(id) on delete cascade,
    variant_id     integer not null references public.product_variants(id) on delete cascade,
    system_qty     integer not null default 0,   -- stock на момент snapshot'а
    reserved_qty   integer not null default 0,   -- в резерве открытых заказов
    quarantine_qty integer not null default 0,   -- в карантине (возвраты)
    expected_qty   integer not null default 0,   -- = system + reserved + quarantine
    fact_qty       integer,                      -- введённый факт (null — не считали)
    diff           integer,                      -- = fact − expected (null — нет факта)
    counted_by     text,                         -- кто ввёл факт (текст, до M2)
    updated_at     timestamptz,
    unique (session_id, variant_id)
);

-- ----------------------------------------------------------------------------
-- 4. Журнал списаний и излишков (Д5–Д7): qty < 0 — списание, qty > 0 — излишек;
--    session_id — проведение инвентаризации (null — ручное списание);
--    движения карантина (admin_resolve_quarantine) сюда НЕ пишутся — единый
--    журнал склада с типами движений — fp №3b (v0.29.0, ответ 7.13)
-- ----------------------------------------------------------------------------
create table if not exists public.writeoffs (
    id         serial primary key,
    variant_id integer not null references public.product_variants(id),
    qty        integer not null check (qty <> 0),
    reason_id  integer not null references public.writeoff_reasons(id),
    session_id integer references public.inventory_sessions(id),
    comment    text,
    changed_by text not null default 'admin',    -- текстовый автор (до M2)
    created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 5. Индексы
-- ----------------------------------------------------------------------------
create index if not exists inventory_items_session_idx  on public.inventory_items (session_id);
create index if not exists writeoffs_variant_idx        on public.writeoffs (variant_id);
create index if not exists writeoffs_reason_idx         on public.writeoffs (reason_id);
create index if not exists writeoffs_session_idx        on public.writeoffs (session_id);
create index if not exists writeoffs_created_idx        on public.writeoffs (created_at);

-- ----------------------------------------------------------------------------
-- 6. ГЕЙТ АН-21, вариант (б) (решение владельца 7.1 и аналитика Д5 от
--    10.10.2026): минус/ноль остатка — допустимое состояние после проведения
--    инвентаризации. CHECK снимается; защита витрины — условное списание
--    create_order (v9, не меняется); ручные списания — guard `stock + qty >= 0`
--    в RPC скрипта 32 сохранён (минус — только через проведение инвентаризации)
-- ----------------------------------------------------------------------------
alter table public.product_variants
    drop constraint if exists product_variants_stock_check;

comment on column public.product_variants.stock is
    'Доступный (свободный) остаток варианта. С v0.20.0 (решение 10.10.2026, АН-21 вариант (б)) минус/ноль допустимы — только после проведения инвентаризации (CHECK снят скриптом 31); заказ с нулевым/минусовым остатком не создаётся (условное списание create_order), на сборке минус/ноль подсвечивается';

-- ----------------------------------------------------------------------------
-- 7. Посев справочника — 5 причин, БЕЗ «Уценки» (Д11, ответ 7.2 от 10.10.2026;
--    on conflict do nothing — культура F21, повторный прогон — no-op)
-- ----------------------------------------------------------------------------
insert into public.writeoff_reasons (code, name, is_system, is_active, sort_order) values
    ('defect',   'Брак',              false, true, 1),
    ('sample',   'Витринный образец', false, true, 2),
    ('shortage', 'Недостача',         true,  true, 3),
    ('surplus',  'Излишек',           true,  true, 4),
    ('other',    'Прочее',            false, true, 5)
on conflict (code) do nothing;

-- ----------------------------------------------------------------------------
-- 8. RLS (Д10): включён на всех 4 таблицах; writeoff_reasons — 3 анонимные
--    политики (чтение публично — как return_reasons; draft-insert/update —
--    «Управление → Справочники»; DELETE-политики нет — удаление только
--    деактивацией); сессии/лист/журнал — без анонимных политик (запись — RPC
--    скрипта 32, чтение — бандлы; паттерн client_name_history v0.18.0)
-- ----------------------------------------------------------------------------
alter table public.writeoff_reasons   enable row level security;
alter table public.inventory_sessions enable row level security;
alter table public.inventory_items    enable row level security;
alter table public.writeoffs          enable row level security;

drop policy if exists anon_read_writeoff_reasons on public.writeoff_reasons;
create policy anon_read_writeoff_reasons on public.writeoff_reasons
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_writeoff_reasons on public.writeoff_reasons;
create policy draft_anon_insert_writeoff_reasons on public.writeoff_reasons
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_writeoff_reasons on public.writeoff_reasons;
create policy draft_anon_update_writeoff_reasons on public.writeoff_reasons
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

-- ----------------------------------------------------------------------------
-- 9. Комментарии таблиц и колонок
-- ----------------------------------------------------------------------------
comment on table public.writeoff_reasons is
    'Справочник причин списаний (волна v0.20.0, fp №9; ответ владельца 7.2 от 10.10.2026 — без «Уценки»): управление — «Управление → Справочники» (manage.html); системные причины (shortage/surplus) используются RPC завершения инвентаризации и не деактивируются; удаление — только деактивацией (DELETE-политики нет)';
comment on column public.writeoff_reasons.code is
    'Код причины (латиница, unique): дефект/образец/недостача/излишек/прочее; код системной причины используется в логике RPC (shortage/surplus)';
comment on table public.inventory_sessions is
    'Сессии инвентаризации (волна v0.20.0, fp №9): область — всё или выбранные категории; статусы planned → in_progress → done + cancelled (Д2: переходы только ручные, отмена из любого статуса кроме done, параллельные идущие сессии разрешены — ответ 7.3(а)); участники — id из admin_users (отображение ФИО; настоящая авторизация — с M2, авторство операций текстовое); запись — только через RPC скрипта 32';
comment on column public.inventory_sessions.scope_categories is
    'Массив id категорий при scope=categories (пустой при scope=all)';
comment on column public.inventory_sessions.participants is
    'Массив id привлекаемых администраторов из admin_users (планирование инвентаризации — требование владельца 05.10.2026)';
comment on table public.inventory_items is
    'Лист инвентаризации (волна v0.20.0): строка на вариант области; snapshot на момент создания/старта сессии (system/reserved/quarantine/expected — «ожидаемо физически» = всё, что присутствует на складе, включая зарезервированное и карантин); fact — ввод при пересчёте, diff = fact − expected; unique (session_id, variant_id); расхождение считается от snapshot СТАРТА (продажи во время сессии меняют stock — семантика «ожидаемо на момент старта»)';
comment on column public.inventory_items.expected_qty is
    'Ожидаемо физически = system_qty + reserved_qty + quarantine_qty (всё присутствует на складе: свободное + зарезервированное открытыми заказами + карантин возвратов)';
comment on table public.writeoffs is
    'Журнал списаний и излишков (волна v0.20.0, fp №9): qty < 0 — списание, qty > 0 — излишек («иногда после инвентаризации товары идут в плюс» — требование владельца 05.10.2026); session_id — проведение инвентаризации (причина shortage/surplus, комментарий «Инвентаризация № X»), null — ручное списание (guard stock + qty >= 0); движения карантина НЕ пишутся — единый журнал склада с типами движений проектируется в fp №3b (v0.29.0, ответ 7.13); запись — только через RPC скрипта 32';
comment on column public.writeoffs.qty is
    'Знак: «−» списание / «+» излишек (Д4 — в расхождениях и журнале знаки и цвет)';

-- ----------------------------------------------------------------------------
-- 10. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from (values
        ('public.writeoff_reasons'), ('public.inventory_sessions'),
        ('public.inventory_items'), ('public.writeoffs')) t(name)
      where to_regclass(t.name) is not null) = 4                      as tables_4,        -- ждём t
    (select count(*) from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relrowsecurity
        and c.relname in ('writeoff_reasons', 'inventory_sessions',
                          'inventory_items', 'writeoffs')) = 4         as rls_4,           -- ждём t
    (select count(*) from public.writeoff_reasons) = 5                as seed_5,          -- ждём t
    (select count(*) from public.writeoff_reasons
      where is_system and code in ('shortage', 'surplus')) = 2        as system_2,        -- ждём t
    (select count(*) from pg_policies where schemaname = 'public')  as policies_65,   -- ждём 65
    (select count(*) from pg_constraint
      where conname = 'product_variants_stock_check') = 0             as check_dropped;   -- ждём t
-- Ожидаемая строка самопроверки (psql -At): t|t|t|t|65|t
