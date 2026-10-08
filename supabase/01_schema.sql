-- ============================================================================
--  SISKU (черновик) — СКРИПТ 1: схема — все таблицы конечного состояния (22)
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE (волна v0.17.0, 07.10.2026): состояние базы на
--  v0.16.0-draft одним скриптом. Заменяет исторические скрипты 01, 07, 10, 13, 14, 15, 16 (схема/констрейнты), 19, 21, 22 (таблицы), 23 (колонка).
--  Исторические версии (включая промежуточные версии функций) — замороженный
--  архив supabase/archive/sql-01-25-v0160.md и git-история; номера удалённых
--  скриптов не переиспользуются (SQL-регламент).
--  Идемпотентен: create table if not exists, add column if not exists, DO-guard констрейнты, create index if not exists.
--  Порядок для НОВОГО стенда: 01 → 02 → 03 → 04 → 05 → 09 → 26 → 27.
--  ⚠ НА ЖИВОЙ БАЗЕ (контент отредактирован владельцем) baseline НЕ
--  перезапускать — модель F21: живая база получает только инкременты ≥ 26.
-- ============================================================================


-- 1. Таблицы (порядок исходных скриптов — FK-цели создаются раньше)

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

create table if not exists public.product_variants (
    id         serial primary key,
    product_id integer not null references public.products(id) on delete cascade,
    label      text not null,              -- размер (S, M…) или объём (50 мл…)
    stock      integer not null default 0 check (stock >= 0),
    sort_order integer not null default 1
);

create table if not exists public.site_content (
    id          serial primary key,
    key         text not null unique,      -- hero.title, contacts.phone_display…
    value       text,
    description text,                      -- подсказка: где это видно на сайте
    updated_at  timestamptz not null default now()
);

create table if not exists public.order_statuses (
    id         serial primary key,
    code       text not null unique,
    name       text not null,
    is_final   boolean not null default false,
    sort_order integer not null default 1
);

create table if not exists public.status_transitions (
    from_status_id integer not null references public.order_statuses(id),
    to_status_id   integer not null references public.order_statuses(id),
    primary key (from_status_id, to_status_id)
);

create table if not exists public.payment_methods (
    id        serial primary key,
    code      text not null unique,
    name      text not null,
    is_active boolean not null default true
);

create table if not exists public.delivery_methods (
    id         serial primary key,
    code       text not null unique,
    name       text not null,
    base_price numeric(10,2) not null default 0,   -- минимум; 0 — бесплатно
    price_max  numeric(10,2),                      -- верх вилки цен; пусто — цена уточняется
    is_active  boolean not null default true
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

create table if not exists public.looks (
    id               serial primary key,
    title            text not null,
    description      text,
    discount_percent numeric(5,2) not null default 0 check (discount_percent between 0 and 90),
    is_active        boolean not null default true,
    created_at       timestamptz not null default now()
);

create table if not exists public.look_items (
    id         serial primary key,
    look_id    integer not null references public.looks(id) on delete cascade,
    product_id integer not null references public.products(id),
    variant_id integer references public.product_variants(id),
    sort_order integer not null default 1
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

create table if not exists public.return_reasons (
    id         serial primary key,
    name       text not null,
    is_active  boolean not null default true,
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

create index if not exists idx_orders_client_id on public.orders (client_id);

create index if not exists idx_orders_promo_code_id on public.orders (promo_code_id);

create index if not exists return_requests_order_idx  on public.return_requests (order_id);

create index if not exists return_requests_status_idx on public.return_requests (status, created_at);


-- 4. Включение RLS (все 22 таблицы)

alter table public.brands enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.site_content enable row level security;
alter table public.order_statuses enable row level security;
alter table public.status_transitions enable row level security;
alter table public.payment_methods enable row level security;
alter table public.delivery_methods enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.deliveries enable row level security;
alter table public.order_status_history enable row level security;
alter table public.admin_users enable row level security;
alter table public.promo_codes enable row level security;
alter table public.looks enable row level security;
alter table public.look_items enable row level security;
alter table public.brand_colors enable row level security;
alter table public.brand_templates enable row level security;
alter table public.clients enable row level security;
alter table public.return_reasons enable row level security;
alter table public.return_requests enable row level security;

-- 5. Комментарии

comment on table public.admin_users is 'Черновой список администраторов: роли копятся, страницы не ограничивают';

comment on table public.brand_colors is 'Значения дизайн-токенов витрины: light/dark — цвета, global — типографика';

comment on table public.brand_templates is 'Сохранённые наборы цветов обеих тем: применить / удалить в один клик';

comment on table public.brands is 'Бренды бутика (мультибрендовая витрина)';

comment on table public.categories is 'Категории каталога';

comment on table public.clients is 'Клиентская база: один клиент = один телефон/e-mail; заказы связаны через orders.client_id';

comment on table public.look_items is 'Позиции комплекта: товар + конкретный вариант (размер/объём)';

comment on table public.looks is 'Луки / готовые образы: состав и скидка комплекта';

comment on table public.order_items is 'Позиции заказа со снапшотами: цена и размер не плывут при правках каталога';

comment on table public.product_variants is 'Варианты товара: размер одежды / объём флакона + остаток';

comment on table public.products is 'Товары витрины';

comment on table public.promo_codes is 'Промокоды: проверка и применение только через серверные функции';

comment on table public.return_reasons is 'Причины возврата (справочник «Управление → Справочники»); удаление — только деактивацией';

comment on table public.return_requests is 'Заявки на возврат: своя статусная модель (created → returned_to_stock → verified / rejected); запись — только через RPC';

comment on table public.site_content is 'Тексты и ссылки сайта; правятся без изменения кода';

comment on table public.status_transitions is 'Разрешённые переходы между статусами заказа';

comment on column public.admin_users.password_hash is 'SHA-256 от пароля; в боевой версии заменяется на bcrypt/argon2id';

comment on column public.admin_users.phone is 'Телефон администратора (волна v0.15.0, правка 2.19): в таблице — кликабельный tel:; валидация формата — на клиенте (users.js), пусто — «нет»';

comment on column public.clients.name_confirmed is 'Имя подтверждено администратором (карточка клиента): create_order v7 не перезаписывает full_name новым заказом; полный вариант политики имён — П8а (v1.x)';

comment on column public.orders.is_paid is 'Оплачен полностью; признак, а не статус (решение учебного проекта)';

comment on column public.orders.promo_code_id is 'Промокод заказа, если применялся';

comment on column public.orders.look_id is 'Комплект, если заказ оформлен целиком из лука';

comment on column public.orders.client_id is 'Клиент заказа (связь «один ко многим», промежуточная таблица не нужна)';

comment on column public.orders.promo_discount is 'Фактическая скидка промокода, ₽ (считает сервер)';

comment on column public.orders.look_discount is 'Фактическая скидка комплекта, ₽ (считает сервер)';

comment on column public.product_variants.quarantine_qty is 'Карантин (волна v0.16.0, фикс F51): единицы, вернувшиеся по заявке на возврат и требующие осмотра. В доступный остаток витрины (stock) НЕ входит; осмотр — admin_resolve_quarantine («вернуть в продажу» / «списать»); складские движения — fp №3b (v0.28.0)';

comment on column public.products.image_url is 'Относительный путь в репозитории или полный URL';

comment on column public.return_reasons.sort_order is 'Порядок в списке (имя колонки — по конвенции проекта: order_statuses/product_variants.sort_order)';

comment on column public.return_requests.photo_urls is 'ЗАГЛУШКА: пустой массив до подключения файлового хранилища (M5); загрузка фото покупателем — после хранилища';

comment on column public.return_requests.refund_receipt is 'Реквизиты чека возврата (54-ФЗ) — в макете необязательные; юридический контур M4';

comment on column public.return_requests.created_by is 'Автор (текст, паттерн order_status_history): ''site'' — покупатель с витрины; в боевой версии — FK на пользователей (M2)';


-- ----------------------------------------------------------------------------
-- 6. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from information_schema.tables
      where table_schema = 'public' and table_type = 'BASE TABLE')      as tables_ok,      -- ждём 22
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relrowsecurity)                  as rls_ok,         -- ждём 22
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'product_variants'
        and column_name = 'quarantine_qty')                             as quarantine_col, -- ждём 1
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'clients'
        and column_name = 'name_confirmed')                             as name_conf_col,  -- ждём 1
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'admin_users'
        and column_name = 'phone')                                      as phone_col,      -- ждём 1
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'orders'
        and column_name in ('client_id','promo_discount','look_discount',
                            'promo_code_id','look_id'))                 as orders_cols,    -- ждём 5
    (select count(*) from pg_constraint
      where conname in ('orders_total_nonneg',
                        'product_variants_quarantine_nonneg'))          as wave_constraints; -- ждём 2
