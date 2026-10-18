-- ============================================================================
--  SISKU (черновик) — СКРИПТ 36: бандлы чтения админ-страниц (волна v0.22.1)
-- ============================================================================
--  Цель: оптимизация загрузки админ-панели (задание аналитика 18.10.2026
--  «…можно ли опять собрать бандлы, чтобы уменьшить количество запросов» +
--  находка 4 внутреннего ревью v0.22.0): пять админ-страниц переводятся
--  на ОДИН запрос чтения (грабля №6) — 23 стартовых REST-запроса → 5:
--    • draft_products_bundle    — «Магазин → Товары»      (8 запросов → 1);
--    • draft_manage_bundle      — «Управление → Справочники» (5 → 1);
--    • draft_looks_bundle       — «Магазин → Комплекты»   (4 → 1);
--    • draft_categories_bundle  — «Магазин → Категории»   (3 → 1);
--    • draft_brandbook_bundle   — «Управление → Брендбук» (3 → 1).
--  Новые таблицы/политики/ключи site_content НЕ создаются; состав данных
--  не меняется; функции — только чтение (паттерн draft_admin_bundle,
--  скрипт 09: LANGUAGE sql, SECURITY DEFINER, SET search_path, jsonb).
--  «Склад» остаётся на 2 параллельных RPC (Д1 — бандлы переиспользует
--  «Статистика» admin.html, слияние дублировало бы данные); страницы с
--  одним запросом («Заказы», «Клиенты», «Пользователи», «Сайт», витрина)
--  не трогаются. draft_attrs_bundle сохранён (Д6 — совместимость/отладка;
--  потребитель — бандл «Товаров» воспроизводит его состав дословно).
--  Волна: v0.22.1 (PATCH). Порядок: baseline 01–05, 09 (ревизия 2) →
--  34 → 35 → 36. Живая база (F21): только инкременты; скрипт идемпотентен
--  (create or replace function), повторный прогон — no-op.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.products') is null
       or to_regclass('public.badges') is null
       or to_regclass('public.brand_colors') is null then
        raise exception 'Скрипт 36: не найдены таблицы каталога — сначала выполните baseline 01–05, 09 (ревизия 2)';
    end if;
    if to_regclass('public.category_attrs') is null
       or to_regclass('public.product_attrs') is null then
        raise exception 'Скрипт 36: не найдены таблицы атрибутов — сначала выполните скрипт 34 (порядок строгий: 34 → 35 → 36)';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. draft_products_bundle — страница «Магазин → Товары» (products.js)
--    8 параллельных запросов v0.22.0 → 1 (находка 4 ревью v0.22.0).
--    Ключи 1:1 с прежним state модуля: products/variants/brands/categories/
--    reserved/badges/product_badges/attrs/attr_values.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_products_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'products',   (select coalesce(jsonb_agg(p order by p.article, p.id), '[]'::jsonb)
                     from public.products p),
    'variants',   (select coalesce(jsonb_agg(v order by v.sort_order, v.id), '[]'::jsonb)
                     from public.product_variants v),
    'brands',     (select coalesce(jsonb_agg(b order by b.name, b.id), '[]'::jsonb)
                     from public.brands b),
    'categories', (select coalesce(jsonb_agg(c order by c.id), '[]'::jsonb)
                     from public.categories c),
    -- reserved — формула draft_reserved_map v2 (открытые заказы
    -- new/confirmed/packing; fix F18 — статус paid не участвует)
    'reserved',   (select coalesce(jsonb_agg(jsonb_build_object(
                       'variant_id', t.variant_id, 'reserved', t.qty)
                       order by t.variant_id), '[]'::jsonb)
                    from (select i.variant_id, sum(i.quantity) as qty
                            from public.order_items i
                            join public.orders o on o.id = i.order_id
                            join public.order_statuses s on s.id = o.status_id
                           where s.code in ('new', 'confirmed', 'packing')
                             and i.variant_id is not null
                           group by i.variant_id) t),
    'badges',     (select coalesce(jsonb_agg(b order by b.sort_order, b.id), '[]'::jsonb)
                     from public.badges b),
    'product_badges', (select coalesce(jsonb_agg(pb order by pb.sort_order, pb.id), '[]'::jsonb)
                     from public.product_badges pb),
    -- attrs/attr_values — состав draft_attrs_bundle (скрипт 34) дословно:
    -- активные атрибуты (порядок category_id, sort_order, id) + значения
    -- всех товаров (порядок product_id, attr_id)
    'attrs',      (select coalesce(jsonb_agg(jsonb_build_object(
                       'id', a.id, 'category_id', a.category_id, 'code', a.code,
                       'name', a.name, 'type', a.type, 'enum_values', a.enum_values,
                       'sort_order', a.sort_order, 'show_in_list', a.show_in_list,
                       'is_filterable', a.is_filterable, 'is_active', a.is_active)
                       order by a.category_id, a.sort_order, a.id), '[]'::jsonb)
                     from public.category_attrs a
                    where a.is_active),
    'attr_values', (select coalesce(jsonb_agg(jsonb_build_object(
                       'product_id', v.product_id, 'attr_id', v.attr_id,
                       'value', v.value)
                       order by v.product_id, v.attr_id), '[]'::jsonb)
                     from public.product_attrs v)
);
$$;

comment on function public.draft_products_bundle is 'Бандл страницы «Товары» (волна v0.22.1, грабля №6, находка 4 ревью v0.22.0): products (полные строки, порядок article), variants (product_variants, sort_order), brands (name), categories (id), reserved (формула draft_reserved_map v2 — открытые заказы new/confirmed/packing), badges и product_badges (sort_order, id — включая неактивные, фильтр is_active на клиенте), attrs/attr_values — состав draft_attrs_bundle (активные атрибуты + значения товаров). 8 запросов v0.22.0 → 1';

-- ----------------------------------------------------------------------------
-- 2. draft_manage_bundle — «Управление → Справочники» (manage.js)
--    5 прямых select'ов → 1. Волна v0.23.0: «Уведомления» — ОТДЕЛЬНАЯ
--    страница (ответ Д2 v0230 от 18.10.2026 — «буквально по fp»); бандл
--    остаётся в составе 5 ключей (v1).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_manage_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'deliveries',       (select coalesce(jsonb_agg(m order by m.id), '[]'::jsonb)
                           from public.delivery_methods m),
    'payments',         (select coalesce(jsonb_agg(m order by m.id), '[]'::jsonb)
                           from public.payment_methods m),
    'return_reasons',   (select coalesce(jsonb_agg(r order by r.sort_order, r.id), '[]'::jsonb)
                           from public.return_reasons r),
    'writeoff_reasons', (select coalesce(jsonb_agg(w order by w.sort_order, w.id), '[]'::jsonb)
                           from public.writeoff_reasons w),
    'badges',           (select coalesce(jsonb_agg(b order by b.sort_order, b.id), '[]'::jsonb)
                           from public.badges b)
);
$$;

comment on function public.draft_manage_bundle is 'Бандл страницы «Управление → Справочники» (волна v0.22.1, грабля №6): delivery_methods и payment_methods (порядок id), return_reasons, writeoff_reasons и badges (sort_order, id) — пять справочников одним запросом вместо пяти прямых select; состав 1:1 с load() manage.js v0.22.0. Волна v0.23.0: «Уведомления» — отдельная страница (ответ Д2 v0230), бандл остаётся v1 (5 ключей)';

-- ----------------------------------------------------------------------------
-- 3. draft_looks_bundle — «Магазин → Комплекты» (looks.js)
--    4 прямых select'а → 1.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_looks_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'looks',    (select coalesce(jsonb_agg(l order by l.id desc), '[]'::jsonb)
                   from public.looks l),
    'items',    (select coalesce(jsonb_agg(i order by i.sort_order, i.id), '[]'::jsonb)
                   from public.look_items i),
    'products', (select coalesce(jsonb_agg(p order by p.name, p.id), '[]'::jsonb)
                   from public.products p),
    'variants', (select coalesce(jsonb_agg(v order by v.sort_order, v.id), '[]'::jsonb)
                   from public.product_variants v)
);
$$;

comment on function public.draft_looks_bundle is 'Бандл страницы «Магазин → Комплекты» (волна v0.22.1, грабля №6): looks (id desc), items (look_items, sort_order), products (полные строки, name — выпадающий список состава), variants (product_variants, sort_order) — 4 запроса → 1; состав 1:1 с load() looks.js v0.22.0';

-- ----------------------------------------------------------------------------
-- 4. draft_categories_bundle — «Магазин → Категории» (categories.js)
--    3 прямых select'а → 1. Товары и варианты — ПОДМНОЖЕСТВО колонок
--    (как в select('id,article,name,price,is_active,category_id') и
--    select('product_id,label,stock') модуля v0.22.0). Конструктор
--    атрибутов категории — прежний ленивый прямой select category_attrs
--    (включая неактивные — для повторной активации; вне стартового чтения).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_categories_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'categories', (select coalesce(jsonb_agg(c order by c.id), '[]'::jsonb)
                     from public.categories c),
    'products',   (select coalesce(jsonb_agg(jsonb_build_object(
                       'id', p.id, 'article', p.article, 'name', p.name,
                       'price', p.price, 'is_active', p.is_active,
                       'category_id', p.category_id)
                       order by p.id), '[]'::jsonb)
                     from public.products p),
    'variants',   (select coalesce(jsonb_agg(jsonb_build_object(
                       'product_id', v.product_id, 'label', v.label,
                       'stock', v.stock)
                       order by v.product_id, v.id), '[]'::jsonb)
                     from public.product_variants v)
);
$$;

comment on function public.draft_categories_bundle is 'Бандл страницы «Магазин → Категории» (волна v0.22.1, грабля №6): categories (полные строки, id), products — подмножество 6 полей (id, article, name, price, is_active, category_id — модалка связей и счётчики), variants — подмножество 3 полей (product_id, label, stock); конструктор атрибутов — прежний ленивый прямой select category_attrs (anon_read_category_attrs, скрипт 34)';

-- ----------------------------------------------------------------------------
-- 5. draft_brandbook_bundle — «Управление → Брендбук» (brandbook.js)
--    3 прямых select'а → 1. Точка синхронизации: список ключей names —
--    NAME_KEYS в brandbook.js (theme.light.name, theme.light.role,
--    theme.dark.name, theme.dark.role — правка 2.17, скрипт 20);
--    изменение списка — только парой (функция + модуль).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_brandbook_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'colors',    (select coalesce(jsonb_agg(bc order by bc.theme, bc.key, bc.id), '[]'::jsonb)
                    from public.brand_colors bc),
    'templates', (select coalesce(jsonb_agg(t order by t.created_at desc, t.id desc), '[]'::jsonb)
                    from public.brand_templates t),
    'names',     (select coalesce(jsonb_agg(jsonb_build_object(
                      'key', sc.key, 'value', sc.value)
                      order by sc.key), '[]'::jsonb)
                    from public.site_content sc
                   where sc.key in ('theme.light.name', 'theme.light.role',
                                    'theme.dark.name', 'theme.dark.role'))
);
$$;

comment on function public.draft_brandbook_bundle is 'Бандл страницы «Управление → Брендбук» (волна v0.22.1, грабля №6): colors (brand_colors — токены обеих тем и global), templates (brand_templates, created_at desc), names (site_content key/value по списку NAME_KEYS brandbook.js — theme.light.name/role, theme.dark.name/role; точка синхронизации с модулем) — 3 запроса → 1';

-- ----------------------------------------------------------------------------
-- Самопроверка (точные ожидаемые значения; функции — явный список 38 проектных
-- имён, методика Д11; rls_auto_enable — платформенная, вне списка, АН-30)
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_tables   where schemaname = 'public')            as tables_32,      -- ждём 32
    (select count(*) from pg_policies where schemaname = 'public')            as policies_74,    -- ждём 74 (новых политик нет)
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = any (array['draft_phone_key', 'draft_email_key', 'check_promo', 'create_order', 'admin_set_status', 'admin_set_paid', 'track_order', 'draft_save_look', 'create_return_request', 'admin_set_return_status', 'admin_set_return_refund', 'admin_resolve_quarantine', 'admin_update_client', 'admin_create_inventory_session', 'admin_start_inventory_session', 'admin_cancel_inventory_session', 'admin_save_inventory_items', 'admin_finish_inventory_session', 'admin_create_writeoff', 'draft_save_product_badges', 'draft_reserved_map', 'draft_admin_bundle', 'draft_assembly_bundle', 'draft_clients_bundle', 'draft_storefront_bundle', 'draft_returns_bundle', 'draft_client_card_bundle', 'draft_inventory_bundle', 'draft_writeoffs_bundle', 'admin_save_category_attr', 'admin_delete_category_attr', 'draft_save_product_attrs', 'draft_attrs_bundle', 'draft_products_bundle', 'draft_manage_bundle', 'draft_looks_bundle', 'draft_categories_bundle', 'draft_brandbook_bundle']))                                                                                             as funcs_38,       -- ждём 38
    (select count(*) from public.site_content)                                as keys_73,        -- ждём 73 (новых ключей нет)
    (select jsonb_typeof(public.draft_products_bundle()   -> 'products')   = 'array'
        and jsonb_typeof(public.draft_manage_bundle()     -> 'badges')     = 'array'
        and jsonb_typeof(public.draft_looks_bundle()      -> 'looks')      = 'array'
        and jsonb_typeof(public.draft_categories_bundle() -> 'categories') = 'array'
        and jsonb_typeof(public.draft_brandbook_bundle()  -> 'names')      = 'array')            as bundles_5_ok;     -- ждём t
-- Ожидаемая строка самопроверки (psql -At): 32|74|38|73|t

-- Справочно (не сравнивается; методика Д11): голое число функций в public —
-- на свежей базе 38, на живой 39 (платформенная rls_auto_enable — решение
-- АН-30 «оставить»):
select count(*) as funcs_total_reference
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public';
