-- ============================================================================
--  SISKU (черновик) — СКРИПТ 33: бейджи карточки товара — схема, посев, RPC
-- ============================================================================
--  Волна v0.21.0 (10.10.2026) — «Бейджи» (fp №16, приоритет №5 согласованного
--  порядка; план развития §3.5, оценка M; решения аналитика Д1–Д12 от
--  10.10.2026; ответы владельца 7.4–7.7, опросник ред. 1.6):
--    (1) таблицы `badges` (справочник: code, name, is_system, is_active,
--        sort_order; БЕЗ auto_remove_days — срок авто-снятия отправлен
--        в fp №16b, Д1) и `product_badges` (назначения товар ↔ бейдж,
--        unique (product_id, badge_id), порядок sort_order);
--    (2) посев — 5 бейджей, состав утверждён владельцем 05.10.2026:
--        New (системный), Хит, Заканчивается (название — выбор владельца
--        06.10.2026, вопрос 6.3), Скоро, % (акция); «New» — ВСЕМ товарам
--        по умолчанию (ответ 1.9; стартовое назначение — посевом, Д7 —
--        включая неактивные; новым товарам — предвыбор в форме создания, Д2);
--    (3) все назначения и снятия — ТОЛЬКО ручные (ответы 7.4–7.6: снятие
--        «New» вручную; «Заканчивается»/«%» — вручную, автоматика — fp №16b
--        и связка с fp №17); «Скоро» — в том числе на карточки без остатка
--        (ответ 7.7; «В корзину» у них скрыта — v0.16.0);
--    (4) RPC `draft_save_product_badges(p jsonb)` — сохранение набора бейджей
--        товара ОДНОЙ транзакцией (Д3, паттерн draft_save_look скрипта 17);
--    (5) `draft_storefront_bundle` v3 — ключи `badges` (активные) и
--        `product_badges` (назначения активных бейджей): витрина рендерит
--        бейджи по справочнику вместо хардкода «New по created_at» (Д6);
--        универсальный стиль пилюли — из токенов брендбука (решение владельца
--        05.10.2026); `create_order` НЕ меняется (v9) — бейджи на заказ
--        не влияют.
--  RLS (Д5): включён на обеих таблицах; `badges` — anon-чтение +
--  draft-insert/update (+3 политики, паттерн `writeoff_reasons` скрипта 31;
--  DELETE-политики нет — удаление только деактивацией); `product_badges` —
--  draft-CRUD полностью (+4 политики, паттерн каталога baseline 02 —
--  осознанная граница черновика, SECURITY.md). Итого +7 политик: 65 → 72.
--  Самопроверка функций — МЕТОДИКА Д11 (решение аналитика 10.10.2026 по
--  находке 1 сверки v0.20.0, трекер АН-30): считается количество ПРОЕКТНЫХ
--  функций по явному списку имён (29) — дрейф живой базы (функции вне
--  списка) на самопроверку не влияет; голое общее число — справочным
--  запросом в конце (не сравнивается).
--  Регэкспы — БЕЗ якорей-долларов (урок v0.19.0: одиночные доллары в
--  скриптах под запретом, скан check-repo): проверка «только цифры» —
--  паттерном «содержит не-цифру» [^0-9].
--  Идемпотентен: create table if not exists + drop/create policy + on
--  conflict do nothing + create or replace function. Порядок: после baseline
--  01–05, 09 и инкрементов 26–32. Применим к живой базе (инкремент — F21):
--  посев добавляет только отсутствующие бейджи и назначения; повторный
--  прогон — no-op.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: скрипт должен выполняться в проекте Sisku после baseline
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.products') is null then
        raise exception 'Скрипт 33: таблица products не найдена — выбран не тот проект Supabase или не выполнен baseline 01';
    end if;
    if to_regprocedure('public.draft_storefront_bundle()') is null then
        raise exception 'Скрипт 33: функция draft_storefront_bundle не найдена — сначала выполните baseline 01–05, 09 и инкременты 26–32';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Справочник бейджей (Д1 — без auto_remove_days; резерв — fp №16b)
-- ----------------------------------------------------------------------------
create table if not exists public.badges (
    id         serial primary key,
    code       text not null unique,          -- new, hit, ending, soon, percent
    name       text not null,                 -- New, Хит, Заканчивается, Скоро, %
    is_system  boolean not null default false,-- New — системный (не деактивируется)
    is_active  boolean not null default true,
    sort_order integer not null default 1,
    created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 2. Назначения товар ↔ бейдж (Д3: запись набора — через RPC; draft-CRUD —
--    граница черновика)
-- ----------------------------------------------------------------------------
create table if not exists public.product_badges (
    id         serial primary key,
    product_id integer not null references public.products(id) on delete cascade,
    badge_id   integer not null references public.badges(id),
    sort_order integer not null default 1,    -- порядок пилюль на витрине
    created_at timestamptz not null default now(),
    unique (product_id, badge_id)
);

create index if not exists product_badges_product_idx on public.product_badges (product_id);
create index if not exists product_badges_badge_idx   on public.product_badges (badge_id);

-- ----------------------------------------------------------------------------
-- 3. Посев справочника — 5 бейджей (состав утверждён владельцем 05.10.2026;
--    название «Заканчивается» — 06.10.2026; F21 — только отсутствующие)
-- ----------------------------------------------------------------------------
insert into public.badges (code, name, is_system, sort_order) values
    ('new',     'New',             true,  1),
    ('hit',     'Хит',             false, 2),
    ('ending',  'Заканчивается',   false, 3),
    ('soon',    'Скоро',           false, 4),
    ('percent', '%',               false, 5)
on conflict (code) do nothing;

-- ----------------------------------------------------------------------------
-- 4. Стартовое назначение: «New» — всем товарам (ответ 1.9, Д7 — включая
--    неактивные; F21 — только отсутствующие)
-- ----------------------------------------------------------------------------
insert into public.product_badges (product_id, badge_id, sort_order)
select p.id, b.id, 1
  from public.products p
 cross join public.badges b
 where b.code = 'new'
on conflict (product_id, badge_id) do nothing;

-- ----------------------------------------------------------------------------
-- 5. RLS (Д5): badges — публичное чтение + draft-insert/update (без delete —
--    удаление только деактивацией, паттерн writeoff_reasons); product_badges —
--    draft-CRUD полностью (паттерн каталога baseline 02). +7 политик → 72
-- ----------------------------------------------------------------------------
alter table public.badges         enable row level security;
alter table public.product_badges enable row level security;

drop policy if exists anon_read_badges on public.badges;
create policy anon_read_badges on public.badges
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_badges on public.badges;
create policy draft_anon_insert_badges on public.badges
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_badges on public.badges;
create policy draft_anon_update_badges on public.badges
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_read_product_badges on public.product_badges;
create policy draft_anon_read_product_badges on public.product_badges
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_product_badges on public.product_badges;
create policy draft_anon_insert_product_badges on public.product_badges
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_product_badges on public.product_badges;
create policy draft_anon_update_product_badges on public.product_badges
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_delete_product_badges on public.product_badges;
create policy draft_anon_delete_product_badges on public.product_badges
    as permissive
    for delete
    to anon, authenticated
    using (true);

-- ----------------------------------------------------------------------------
-- 6. Комментарии таблиц и колонок
-- ----------------------------------------------------------------------------
comment on table public.badges is
    'Справочник бейджей карточки товара (волна v0.21.0, fp №16): состав утверждён владельцем 05.10.2026 — New (системный), Хит, Заканчивается (название — выбор владельца 06.10.2026), Скоро, % (акция); владелец меняет состав сам из «Управление → Справочники» (сценарий «−20%» — ответ 7.6); все назначения/снятия ручные (ответы 7.4–7.6; автоматика и срок авто-снятия — fp №16b); удаление — только деактивацией (DELETE-политики нет); стиль пилюль на витрине — универсальный, из токенов брендбука (решение владельца 05.10.2026)';
comment on column public.badges.code is
    'Код бейджа (латиница, unique): new/hit/ending/soon/percent; код "new" используется посевом (стартовое назначение всем товарам) и формой создания товара (предвыбор — Д2); системный бейдж не деактивируется (guard админки)';
comment on column public.badges.is_system is
    'Системный бейдж (New): назначается всем товарам посевом скрипта 33 и предлагается по умолчанию при создании товара; деактивация справочником запрещена (значок + disabled, паттерн системных причин списаний v0.20.0); снятие с товара — только вручную (ответ 7.4)';
comment on table public.product_badges is
    'Назначения бейджей товарам (волна v0.21.0, fp №16): unique (product_id, badge_id); sort_order — порядок пилюль на витрине; сохранение набора — RPC draft_save_product_badges одной транзакцией (Д3); draft-CRUD-политики — в пределах задокументированной границы черновика (SECURITY.md)';

-- ----------------------------------------------------------------------------
-- 7. draft_save_product_badges — сохранение набора бейджей товара (Д3)
--    Валидации «только цифры» — паттерном [^0-9] без якоря-доллара (урок
--    v0.19.0: одиночные доллары в скриптах под запретом)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_save_product_badges(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_pid_text text;
    v_product_id integer;
    v_ids      jsonb;
    v_seen     integer[] := '{}';
    v_sort     integer := 0;
    v_name     text;
    rec        record;
begin
    if p is null or jsonb_typeof(p) <> 'object' then
        raise exception 'Параметр p — не объект';
    end if;

    v_pid_text := trim(coalesce(p->>'product_id', ''));
    if v_pid_text = '' or v_pid_text ~ '[^0-9]' then
        raise exception 'product_id не указан или не число';
    end if;
    v_product_id := v_pid_text::integer;
    if not exists (select 1 from public.products where id = v_product_id) then
        raise exception 'Товар не найден: id %', v_product_id;
    end if;

    v_ids := coalesce(p->'badge_ids', '[]'::jsonb);
    if jsonb_typeof(v_ids) <> 'array' then
        raise exception 'badge_ids — не массив';
    end if;
    if exists (select 1 from jsonb_array_elements_text(v_ids) as t(v)
                where nullif(trim(t.v), '') is not null
                  and trim(t.v) ~ '[^0-9]') then
        raise exception 'ID бейджа — не число';
    end if;

    -- Замена набора одной транзакцией: delete → insert в порядке массива
    -- (ошибка валидации — откат, товар не остаётся без набора случайно)
    delete from public.product_badges where product_id = v_product_id;

    for rec in
        select nullif(trim(t.v), '')::integer as badge_id
          from jsonb_array_elements_text(v_ids) with ordinality as t(v, ord)
         order by t.ord
    loop
        if rec.badge_id is null then
            continue;                                    -- пустые элементы — пропускаем
        end if;
        if rec.badge_id = any (v_seen) then
            continue;                                    -- дубли — схлопываются
        end if;
        select b.name into v_name
          from public.badges b
         where b.id = rec.badge_id and b.is_active;
        if v_name is null then
            raise exception 'Бейдж не найден или неактивен: id %', rec.badge_id;
        end if;
        v_seen := v_seen || rec.badge_id;
        v_sort := v_sort + 1;
        insert into public.product_badges (product_id, badge_id, sort_order)
        values (v_product_id, rec.badge_id, v_sort);
    end loop;

    return jsonb_build_object('ok', true, 'count', v_sort);
end;
$$;

comment on function public.draft_save_product_badges is
    'v1 (волна v0.21.0, fp №16 — бейджи; Д3): сохранение набора бейджей товара одной транзакцией — delete → insert в порядке массива (sort_order = позиция); дубли схлопываются; валидации: товар существует, badge_ids — массив чисел, каждый бейдж активен; пустой массив = снять все (в т.ч. New — снятие только ручное, ответ 7.4); p = { product_id, badge_ids: [int] } → { ok, count }; прототип боевого PATCH /api/products/:id/badges';

-- ----------------------------------------------------------------------------
-- 8. draft_storefront_bundle v3 — + badges и product_badges (Д6; v2-ключи
--    волны v0.16.0 без изменений)
-- ----------------------------------------------------------------------------
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

comment on function public.draft_storefront_bundle is
    'v3 (волна v0.21.0): + badges (активный справочник) и product_badges (назначения только активных бейджей) — витрина рендерит бейджи карточек по справочнику вместо хардкода «New по created_at» (fp №16, Д6); v2-ключи (волна v0.16.0 — return_reasons и пр.) без изменений; все данные витрины одним RPC — грабля №6';

-- ----------------------------------------------------------------------------
-- 9. Самопроверка (методика Д11: проектные функции — по явному списку;
--    голое общее число — справочным запросом ниже, НЕ сравнивается)
-- ----------------------------------------------------------------------------
select
    (select to_regclass('public.badges') is not null)                        as badges_table,   -- ждём t
    (select to_regclass('public.product_badges') is not null)                as pb_table,       -- ждём t
    (select count(*) = 5 from public.badges)                                 as seed_5,         -- ждём t
    (select coalesce((select is_system from public.badges
                       where code = 'new'), false))                          as new_system,     -- ждём t
    (select (select count(*) from public.product_badges pb
              join public.badges b on b.id = pb.badge_id
             where b.code = 'new')
          = (select count(*) from public.products))                          as new_all,        -- ждём t
    (select to_regprocedure('public.draft_save_product_badges(jsonb)') is not null)
                                                                             as rpc_save,       -- ждём t
    (select count(*) from pg_policies where schemaname = 'public')           as policies_72,    -- ждём 72
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = any (array[
            'create_order', 'admin_set_status', 'admin_set_paid', 'check_promo',
            'track_order', 'draft_save_look', 'draft_phone_key', 'draft_email_key',
            'create_return_request', 'admin_set_return_status', 'admin_set_return_refund',
            'admin_resolve_quarantine',
            'draft_admin_bundle', 'draft_assembly_bundle', 'draft_clients_bundle',
            'draft_storefront_bundle', 'draft_reserved_map', 'draft_returns_bundle',
            'admin_update_client', 'draft_client_card_bundle',
            'admin_create_inventory_session', 'admin_start_inventory_session',
            'admin_cancel_inventory_session', 'admin_save_inventory_items',
            'admin_finish_inventory_session', 'admin_create_writeoff',
            'draft_inventory_bundle', 'draft_writeoffs_bundle',
            'draft_save_product_badges']))                                   as project_funcs_29, -- ждём 29
    (select obj_description(oid, 'pg_proc') like 'v3%' from pg_proc
      where proname = 'draft_storefront_bundle')                             as bundle_v3;      -- ждём t
-- Ожидаемая строка самопроверки (psql -At): t|t|t|t|t|t|72|29|t

-- Справочно (АН-30 — не сравнивается с эталоном; на свежей базе равно 29,
-- на живой может превышать на число функций дрейфа — находка 1 сверки v0.20.0):
select count(*) as func_total_info
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public';
