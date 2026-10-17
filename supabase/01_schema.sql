-- ============================================================================
--  SISKU (черновик) — СКРИПТ 01: схема — все 30 таблиц конечного состояния (консолидация v0.21.1)
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

-- 0. Префлайт не требуется — скрипт 01 открывает цепочку

-- 1. Таблицы (30; порядок — по FK-зависимостям)

create table if not exists public.admin_users (
    id             serial primary key,
    fio            text not null,
    email          text not null,
    messenger_url  text,
    role           text not null check (role in ('admin', 'assembler', 'manager', 'partner')),
    password_hash  text not null,          -- SHA-256 (только для макета!)
    is_active      boolean not null default true,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

create table if not exists public.badges (
    id         serial primary key,
    code       text not null unique,          -- new, hit, ending, soon, percent
    name       text not null,                 -- New, Хит, Заканчивается, Скоро, %
    is_system  boolean not null default false,-- New — системный (не деактивируется)
    is_active  boolean not null default true,
    sort_order integer not null default 1,
    created_at timestamptz not null default now()
);

create table if not exists public.brand_colors (
    id     serial primary key,
    theme  text not null check (theme in ('light', 'dark', 'global')),
    key    text not null,
    value  text not null,
    unique (theme, key)
);

create table if not exists public.brand_templates (
    id         serial primary key,
    name       text not null,
    comment    text,
    colors     jsonb not null,          -- {light:{bg:…}, dark:{bg:…}, global:{typo_base:…}}
    created_at timestamptz not null default now()
);

create table if not exists public.brands (
    id        serial primary key,
    name      text not null,
    country   text,
    is_active boolean not null default true
);

create table if not exists public.categories (
    id          serial primary key,
    slug        text not null unique,
    name        text not null,
    description text
);

create table if not exists public.clients (
    id         serial primary key,
    full_name  text not null,
    phone      text,
    email      text,
    address    text,                          -- последний адрес доставки из заказов
    note       text,                          -- комментарий менеджера
    phone_key  text unique,                   -- 7XXXXXXXXXX или null
    email_key  text unique,                   -- нижний регистр или null
    created_at timestamptz not null default now(),   -- дата первого заказа
    updated_at timestamptz not null default now()
);

create table if not exists public.delivery_methods (
    id         serial primary key,
    code       text not null unique,
    name       text not null,
    base_price numeric(10,2) not null default 0,   -- минимум; 0 — бесплатно
    price_max  numeric(10,2),                      -- верх вилки цен; пусто — цена уточняется
    is_active  boolean not null default true
);

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

create table if not exists public.looks (
    id               serial primary key,
    title            text not null,
    description      text,
    discount_percent numeric(5,2) not null default 0 check (discount_percent between 0 and 90),
    is_active        boolean not null default true,
    created_at       timestamptz not null default now()
);

create table if not exists public.order_statuses (
    id         serial primary key,
    code       text not null unique,
    name       text not null,
    is_final   boolean not null default false,
    sort_order integer not null default 1
);

create table if not exists public.payment_methods (
    id        serial primary key,
    code      text not null unique,
    name      text not null,
    is_active boolean not null default true
);

create table if not exists public.promo_codes (
    id               serial primary key,
    code             text not null unique,
    discount_type    text not null check (discount_type in ('percent', 'fixed')),
    discount_value   numeric(10,2) not null check (discount_value > 0),
    min_order_amount numeric(10,2) not null default 0,
    valid_from       date,
    valid_until      date,
    usage_limit      integer,                      -- пусто — без лимита
    used_count       integer not null default 0,
    is_active        boolean not null default true,
    created_at       timestamptz not null default now()
);

create table if not exists public.return_reasons (
    id         serial primary key,
    name       text not null,
    is_active  boolean not null default true,
    sort_order integer not null default 1
);

create table if not exists public.site_content (
    id          serial primary key,
    key         text not null unique,      -- hero.title, contacts.phone_display…
    value       text,
    description text,                      -- подсказка: где это видно на сайте
    updated_at  timestamptz not null default now()
);

create table if not exists public.writeoff_reasons (
    id         serial primary key,
    code       text not null unique,       -- defect, sample, shortage…
    name       text not null,
    is_system  boolean not null default false,  -- системные не деактивируются
    is_active  boolean not null default true,
    sort_order integer not null default 1
);

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

create table if not exists public.client_name_history (
    id         serial primary key,
    client_id  integer not null references public.clients(id) on delete cascade,
    full_name  text not null,
    source     text not null default 'order'
               check (source in ('order', 'admin', 'merge', 'backfill')),
    created_by text not null default 'site',
    created_at timestamptz not null default now()
);

create table if not exists public.orders (
    id                 serial primary key,        -- номер заказа, который видит клиент
    created_at         timestamptz not null default now(),
    customer_name      text not null,
    customer_phone     text,
    customer_email     text,
    customer_address   text,                       -- город, адрес или пункт выдачи
    status_id          integer not null references public.order_statuses(id),
    payment_method_id  integer references public.payment_methods(id),
    delivery_method_id integer references public.delivery_methods(id),
    total              numeric(10,2) not null default 0,   -- сумма товаров
    delivery_cost      numeric(10,2) not null default 0,
    comment            text,
    is_paid            boolean not null default false,   -- признак, а не статус
    paid_at            timestamptz
);

create table if not exists public.products (
    id          serial primary key,
    article     text not null unique,      -- внутренний артикул: 10001, 20003
    name        text not null,
    price       numeric(10,2) not null check (price >= 0),
    brand_id    integer references public.brands(id),
    category_id integer references public.categories(id),
    description text,
    image_url   text,                       -- пусто — на сайте показывается заглушка
    is_active   boolean not null default true,
    created_at  timestamptz not null default now()
);

create table if not exists public.status_transitions (
    from_status_id integer not null references public.order_statuses(id),
    to_status_id   integer not null references public.order_statuses(id),
    primary key (from_status_id, to_status_id)
);

create table if not exists public.deliveries (
    id                 serial primary key,
    order_id           integer not null references public.orders(id) on delete cascade,
    delivery_method_id integer references public.delivery_methods(id),
    address            text,
    tracking_number    text,
    cost               numeric(10,2) not null default 0,
    comment            text
);

create table if not exists public.order_status_history (
    id         serial primary key,
    order_id   integer not null references public.orders(id) on delete cascade,
    status_id  integer not null references public.order_statuses(id),
    changed_at timestamptz not null default now(),
    changed_by text not null default 'system',
    comment    text
);

create table if not exists public.product_badges (
    id         serial primary key,
    product_id integer not null references public.products(id) on delete cascade,
    badge_id   integer not null references public.badges(id),
    sort_order integer not null default 1,    -- порядок пилюль на витрине
    created_at timestamptz not null default now(),
    unique (product_id, badge_id)
);

create table if not exists public.product_variants (
    id         serial primary key,
    product_id integer not null references public.products(id) on delete cascade,
    label      text not null,              -- размер (S, M…) или объём (50 мл…)
    stock      integer not null default 0,
    sort_order integer not null default 1
);

create table if not exists public.return_requests (
    id             serial primary key,          -- номер заявки, который видит клиент
    order_id       integer not null references public.orders(id),
    reason_id      integer not null references public.return_reasons(id),
    comment        text,
    photo_urls     jsonb not null default '[]'::jsonb,   -- заглушка до хранилища (M5)
    status         text not null default 'created'
                   check (status in ('created', 'returned_to_stock', 'verified', 'rejected')),
    refund_paid    boolean not null default false,
    refund_paid_at timestamptz,
    refund_receipt text,                        -- реквизиты чека возврата; в макете необязательные (M4)
    created_by     text not null default 'site',
    handled_by     text,
    created_at     timestamptz not null default now(),
    resolved_at    timestamptz
);

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

create table if not exists public.look_items (
    id         serial primary key,
    look_id    integer not null references public.looks(id) on delete cascade,
    product_id integer not null references public.products(id),
    variant_id integer references public.product_variants(id),
    sort_order integer not null default 1
);

create table if not exists public.order_items (
    id               serial primary key,
    order_id         integer not null references public.orders(id) on delete cascade,
    product_id       integer references public.products(id),
    variant_id       integer references public.product_variants(id),
    quantity         integer not null check (quantity between 1 and 99),
    price            numeric(10,2) not null,   -- снапшот цены на момент заказа
    title_snapshot   text not null,            -- снапшот названия
    variant_snapshot text                      -- снапшот размера/объёма
);

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

-- 2. Колонки и констрейнты исторических волн (дословно из baseline ревизии 1;
--    все операторы идемпотентны)
-- 2. Колонки и констрейнты, добавленные историческими волнами

alter table public.orders add column if not exists promo_code_id integer references public.promo_codes(id);

alter table public.orders add column if not exists look_id integer references public.looks(id);

alter table public.orders add column if not exists client_id integer references public.clients(id) on delete set null;

alter table public.orders add column if not exists promo_discount numeric(10,2) not null default 0;

alter table public.orders add column if not exists look_discount numeric(10,2) not null default 0;

alter table public.clients
    add column if not exists name_confirmed boolean not null default false;

alter table public.admin_users
    add column if not exists phone text;

alter table public.product_variants
    add column if not exists quarantine_qty integer not null default 0;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'orders_total_nonneg'
          and conrelid = 'public.orders'::regclass
    ) then
        if exists (select 1 from public.orders where total < 0) then
            raise exception 'DANGER: в orders остались строки с total < 0 — констрейнт не добавить. Выполните блок 4 вручную после разбора данных.';
        end if;
        alter table public.orders add constraint orders_total_nonneg check (total >= 0);
    end if;
end $$;

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

comment on constraint orders_total_nonneg on public.orders is
    'Итог заказа (за вычетом скидок) не может быть отрицательным — fix F07 (ревью v0.13.1)';

-- 3. Индексы
create index if not exists client_contact_history_client_idx ON public.client_contact_history USING btree (client_id, created_at);
create index if not exists client_name_history_client_idx ON public.client_name_history USING btree (client_id, created_at);
create index if not exists idx_orders_client_id ON public.orders USING btree (client_id);
create index if not exists idx_orders_promo_code_id ON public.orders USING btree (promo_code_id);
create index if not exists inventory_items_session_idx ON public.inventory_items USING btree (session_id);
create index if not exists product_badges_badge_idx ON public.product_badges USING btree (badge_id);
create index if not exists product_badges_product_idx ON public.product_badges USING btree (product_id);
create index if not exists return_requests_order_idx ON public.return_requests USING btree (order_id);
create index if not exists return_requests_status_idx ON public.return_requests USING btree (status, created_at);
create index if not exists writeoffs_created_idx ON public.writeoffs USING btree (created_at);
create index if not exists writeoffs_reason_idx ON public.writeoffs USING btree (reason_id);
create index if not exists writeoffs_session_idx ON public.writeoffs USING btree (session_id);
create index if not exists writeoffs_variant_idx ON public.writeoffs USING btree (variant_id);

-- 3. RLS включён на всех таблицах (политики — скрипт 02)
alter table public.admin_users enable row level security;
alter table public.badges enable row level security;
alter table public.brand_colors enable row level security;
alter table public.brand_templates enable row level security;
alter table public.brands enable row level security;
alter table public.categories enable row level security;
alter table public.clients enable row level security;
alter table public.delivery_methods enable row level security;
alter table public.inventory_sessions enable row level security;
alter table public.looks enable row level security;
alter table public.order_statuses enable row level security;
alter table public.payment_methods enable row level security;
alter table public.promo_codes enable row level security;
alter table public.return_reasons enable row level security;
alter table public.site_content enable row level security;
alter table public.writeoff_reasons enable row level security;
alter table public.client_contact_history enable row level security;
alter table public.client_name_history enable row level security;
alter table public.orders enable row level security;
alter table public.products enable row level security;
alter table public.status_transitions enable row level security;
alter table public.deliveries enable row level security;
alter table public.order_status_history enable row level security;
alter table public.product_badges enable row level security;
alter table public.product_variants enable row level security;
alter table public.return_requests enable row level security;
alter table public.inventory_items enable row level security;
alter table public.look_items enable row level security;
alter table public.order_items enable row level security;
alter table public.writeoffs enable row level security;

-- 4. Комментарии (конечное состояние каталога)
comment on table public.admin_users is 'Черновой список администраторов: роли копятся, страницы не ограничивают';
comment on table public.badges is 'Справочник бейджей карточки товара (волна v0.21.0, fp №16): состав утверждён владельцем 05.10.2026 — New (системный), Хит, Заканчивается (название — выбор владельца 06.10.2026), Скоро, % (акция); владелец меняет состав сам из «Управление → Справочники» (сценарий «−20%» — ответ 7.6); все назначения/снятия ручные (ответы 7.4–7.6; автоматика и срок авто-снятия — fp №16b); удаление — только деактивацией (DELETE-политики нет); стиль пилюль на витрине — универсальный, из токенов брендбука (решение владельца 05.10.2026)';
comment on table public.brand_colors is 'Значения дизайн-токенов витрины: light/dark — цвета, global — типографика';
comment on table public.brand_templates is 'Сохранённые наборы цветов обеих тем: применить / удалить в один клик';
comment on table public.brands is 'Бренды бутика (мультибрендовая витрина)';
comment on table public.categories is 'Категории каталога';
comment on table public.client_contact_history is 'История изменения телефонов и e-mail клиента (волна v0.18.0): ведётся так же, как история имён (правило владельца 05.10.2026); прямого доступа нет — только RPC';
comment on table public.client_name_history is 'Варианты имён клиента (волна v0.18.0, fp №1): каждое имя из заказов и каждая правка администратора; правило владельца 05.10.2026 — в карточке видны варианты, которые клиент вводил сам; прямого доступа нет — только RPC';
comment on table public.clients is 'Клиентская база: один клиент = один телефон/e-mail; заказы связаны через orders.client_id';
comment on table public.inventory_items is 'Лист инвентаризации (волна v0.20.0): строка на вариант области; snapshot на момент создания/старта сессии (system/reserved/quarantine/expected — «ожидаемо физически» = всё, что присутствует на складе, включая зарезервированное и карантин); fact — ввод при пересчёте, diff = fact − expected; unique (session_id, variant_id); расхождение считается от snapshot СТАРТА (продажи во время сессии меняют stock — семантика «ожидаемо на момент старта»)';
comment on table public.inventory_sessions is 'Сессии инвентаризации (волна v0.20.0, fp №9): область — всё или выбранные категории; статусы planned → in_progress → done + cancelled (Д2: переходы только ручные, отмена из любого статуса кроме done, параллельные идущие сессии разрешены — ответ 7.3(а)); участники — id из admin_users (отображение ФИО; настоящая авторизация — с M2, авторство операций текстовое); запись — только через RPC скрипта 32';
comment on table public.look_items is 'Позиции комплекта: товар + конкретный вариант (размер/объём)';
comment on table public.looks is 'Луки / готовые образы: состав и скидка комплекта';
comment on table public.order_items is 'Позиции заказа со снапшотами: цена и размер не плывут при правках каталога';
comment on table public.product_badges is 'Назначения бейджей товарам (волна v0.21.0, fp №16): unique (product_id, badge_id); sort_order — порядок пилюль на витрине; сохранение набора — RPC draft_save_product_badges одной транзакцией (Д3); draft-CRUD-политики — в пределах задокументированной границы черновика (SECURITY.md)';
comment on table public.product_variants is 'Варианты товара: размер одежды / объём флакона + остаток';
comment on table public.products is 'Товары витрины';
comment on table public.promo_codes is 'Промокоды: проверка и применение только через серверные функции';
comment on table public.return_reasons is 'Причины возврата (справочник «Управление → Справочники»); удаление — только деактивацией';
comment on table public.return_requests is 'Заявки на возврат: своя статусная модель (created → returned_to_stock → verified / rejected); запись — только через RPC';
comment on table public.site_content is 'Тексты и ссылки сайта; правятся без изменения кода';
comment on table public.status_transitions is 'Разрешённые переходы между статусами заказа';
comment on table public.writeoff_reasons is 'Справочник причин списаний (волна v0.20.0, fp №9; ответ владельца 7.2 от 10.10.2026 — без «Уценки»): управление — «Управление → Справочники» (manage.html); системные причины (shortage/surplus) используются RPC завершения инвентаризации и не деактивируются; удаление — только деактивацией (DELETE-политики нет)';
comment on table public.writeoffs is 'Журнал списаний и излишков (волна v0.20.0, fp №9): qty < 0 — списание, qty > 0 — излишек («иногда после инвентаризации товары идут в плюс» — требование владельца 05.10.2026); session_id — проведение инвентаризации (причина shortage/surplus, комментарий «Инвентаризация № X»), null — ручное списание (guard stock + qty >= 0); движения карантина НЕ пишутся — единый журнал склада с типами движений проектируется в fp №3b (v0.29.0, ответ 7.13); запись — только через RPC скрипта 32';
comment on column public.admin_users.password_hash is 'SHA-256 от пароля; в боевой версии заменяется на bcrypt/argon2id';
comment on column public.admin_users.phone is 'Телефон администратора (волна v0.15.0, правка 2.19): в таблице — кликабельный tel:; валидация формата — на клиенте (users.js), пусто — «нет»';
comment on column public.badges.code is 'Код бейджа (латиница, unique): new/hit/ending/soon/percent; код "new" используется посевом (стартовое назначение всем товарам) и формой создания товара (предвыбор — Д2); системный бейдж не деактивируется (guard админки)';
comment on column public.badges.is_system is 'Системный бейдж (New): назначается всем товарам посевом скрипта 33 и предлагается по умолчанию при создании товара; деактивация справочником запрещена (значок + disabled, паттерн системных причин списаний v0.20.0); снятие с товара — только вручную (ответ 7.4)';
comment on column public.client_contact_history.action is 'set — указан, changed — изменён администратором, offered — предложен в заказе (не принят — решение Д3), invalidated — утратил силу (заменён администратором)';
comment on column public.client_contact_history.changed_by is 'Кто записал: site (заказ с витрины), admin (карточка клиента), backfill (скрипт 28)';
comment on column public.client_name_history.source is 'Источник варианта: order — из заказа, admin — правка карточки, merge — слияние, backfill — исходные данные';
comment on column public.client_name_history.created_by is 'Кто записал: site (заказ с витрины), admin (карточка клиента), backfill (скрипт 28)';
comment on column public.clients.name_confirmed is 'Имя подтверждено администратором (карточка клиента): create_order v7 не перезаписывает full_name новым заказом; полный вариант политики имён — П8а (v1.x)';
comment on column public.inventory_items.expected_qty is 'Ожидаемо физически = system_qty + reserved_qty + quarantine_qty (всё присутствует на складе: свободное + зарезервированное открытыми заказами + карантин возвратов)';
comment on column public.inventory_sessions.scope_categories is 'Массив id категорий при scope=categories (пустой при scope=all)';
comment on column public.inventory_sessions.participants is 'Массив id привлекаемых администраторов из admin_users (планирование инвентаризации — требование владельца 05.10.2026)';
comment on column public.orders.is_paid is 'Оплачен полностью; признак, а не статус (решение учебного проекта)';
comment on column public.orders.promo_code_id is 'Промокод заказа, если применялся';
comment on column public.orders.look_id is 'Комплект, если заказ оформлен целиком из лука';
comment on column public.orders.client_id is 'Клиент заказа (связь «один ко многим», промежуточная таблица не нужна)';
comment on column public.orders.promo_discount is 'Фактическая скидка промокода, ₽ (считает сервер)';
comment on column public.orders.look_discount is 'Фактическая скидка комплекта, ₽ (считает сервер)';
comment on column public.product_variants.stock is 'Доступный (свободный) остаток варианта. С v0.20.0 (решение 10.10.2026, АН-21 вариант (б)) минус/ноль допустимы — только после проведения инвентаризации (CHECK снят скриптом 31); заказ с нулевым/минусовым остатком не создаётся (условное списание create_order), на сборке минус/ноль подсвечивается';
comment on column public.product_variants.quarantine_qty is 'Карантин (волна v0.16.0, фикс F51): единицы, вернувшиеся по заявке на возврат и требующие осмотра. В доступный остаток витрины (stock) НЕ входит; осмотр — admin_resolve_quarantine («вернуть в продажу» / «списать»); складские движения — fp №3b (v0.28.0)';
comment on column public.products.image_url is 'Относительный путь в репозитории или полный URL';
comment on column public.return_reasons.sort_order is 'Порядок в списке (имя колонки — по конвенции проекта: order_statuses/product_variants.sort_order)';
comment on column public.return_requests.photo_urls is 'ЗАГЛУШКА: пустой массив до подключения файлового хранилища (M5); загрузка фото покупателем — после хранилища';
comment on column public.return_requests.refund_receipt is 'Реквизиты чека возврата (54-ФЗ) — в макете необязательные; юридический контур M4';
comment on column public.return_requests.created_by is 'Автор (текст, паттерн order_status_history): ''site'' — покупатель с витрины; в боевой версии — FK на пользователей (M2)';
comment on column public.writeoff_reasons.code is 'Код причины (латиница, unique): дефект/образец/недостача/излишек/прочее; код системной причины используется в логике RPC (shortage/surplus)';
comment on column public.writeoffs.qty is 'Знак: «−» списание / «+» излишек (Д4 — в расхождениях и журнале знаки и цвет)';

-- ----------------------------------------------------------------------------
-- 5. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r')                        as tables_30,   -- ждём 30
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity)   as rls_30,      -- ждём 30
    (select count(*) = 0 from pg_constraint where conname = 'product_variants_stock_check')
                                                                             as no_stock_check, -- ждём t (АН-21 (б))
    (select count(*) from pg_indexes where schemaname = 'public')            as indexes;      -- ждём 57
-- Ожидаемая строка самопроверки (psql -At): 30|30|t|57
