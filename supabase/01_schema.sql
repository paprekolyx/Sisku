-- ============================================================================
--  SISKU (черновик) — СКРИПТ 1: схема базы
-- ============================================================================
--  ЧТО ПОЯВЛЯЕТСЯ
--    Каталог: brands, categories, products, product_variants (размеры/объёмы
--    и остатки), site_content (тексты сайта правятся без кода).
--    Заказы:  orders, order_items (со снапшотами цен и размеров),
--             deliveries, order_status_history.
--    Справочники: order_statuses, status_transitions (модель переходов
--    в стиле Jira), payment_methods, delivery_methods.
--
--  ЧЕГО НЕТ СОЗНАТЕЛЬНО (черновик для оценки дизайна и функций)
--    Пользователей, ролей, сессий, журналов входов и аудита: админ-панель
--    черновика открывается по ссылке без пароля. В боевой версии эти таблицы
--    появятся вместе с настоящей моделью авторизации.
--    Промокоды, отзывы, галереи фото (product_images) — следующие волны.
--
--  ПРАВИЛА (как в учебном проекте)
--    Скрипт идемпотентен: повторный запуск ничего не ломает и не дублирует.
--    Никаких drop table / truncate / delete без where.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Каталог
-- ----------------------------------------------------------------------------
create table if not exists public.brands (
    id        serial primary key,
    name      text not null,
    country   text,
    is_active boolean not null default true
);
comment on table public.brands is 'Бренды бутика (мультибрендовая витрина)';

create table if not exists public.categories (
    id          serial primary key,
    slug        text not null unique,
    name        text not null,
    description text
);
comment on table public.categories is 'Категории каталога';

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
comment on table  public.products is 'Товары витрины';
comment on column public.products.image_url is 'Относительный путь в репозитории или полный URL';

create table if not exists public.product_variants (
    id         serial primary key,
    product_id integer not null references public.products(id) on delete cascade,
    label      text not null,              -- размер (S, M…) или объём (50 мл…)
    stock      integer not null default 0 check (stock >= 0),
    sort_order integer not null default 1
);
comment on table public.product_variants is 'Варианты товара: размер одежды / объём флакона + остаток';

create table if not exists public.site_content (
    id          serial primary key,
    key         text not null unique,      -- hero.title, contacts.phone_display…
    value       text,
    description text,                      -- подсказка: где это видно на сайте
    updated_at  timestamptz not null default now()
);
comment on table public.site_content is 'Тексты и ссылки сайта; правятся без изменения кода';

-- ----------------------------------------------------------------------------
-- 2. Справочники статусов, оплаты, доставки
-- ----------------------------------------------------------------------------
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
comment on table public.status_transitions is 'Разрешённые переходы между статусами заказа';

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

-- ----------------------------------------------------------------------------
-- 3. Заказы
-- ----------------------------------------------------------------------------
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
comment on column public.orders.is_paid is 'Оплачен полностью; признак, а не статус (решение учебного проекта)';

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
comment on table public.order_items is 'Позиции заказа со снапшотами: цена и размер не плывут при правках каталога';

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

-- RLS включаем сразу на всех таблицах; политики — в скрипте 02.
alter table public.brands               enable row level security;
alter table public.categories           enable row level security;
alter table public.products             enable row level security;
alter table public.product_variants     enable row level security;
alter table public.site_content         enable row level security;
alter table public.order_statuses       enable row level security;
alter table public.status_transitions   enable row level security;
alter table public.payment_methods      enable row level security;
alter table public.delivery_methods     enable row level security;
alter table public.orders               enable row level security;
alter table public.order_items          enable row level security;
alter table public.deliveries           enable row level security;
alter table public.order_status_history enable row level security;
