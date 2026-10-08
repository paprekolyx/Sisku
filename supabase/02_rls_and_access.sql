-- ============================================================================
--  SISKU (черновик) — СКРИПТ 2: политики RLS — все 62 политики конечного состояния
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE (волна v0.17.0, 07.10.2026): состояние базы на
--  v0.16.0-draft одним скриптом. Заменяет исторические скрипты 02, 07 (политики), 09–16 (политики), 22, 23.
--  Исторические версии (включая промежуточные версии функций) — замороженный
--  архив supabase/archive/sql-01-25-v0160.md и git-история; номера удалённых
--  скриптов не переиспользуются (SQL-регламент).
--  Идемпотентен: drop policy if exists + create policy; префлайт to_regclass по всем таблицам.
--  Порядок для НОВОГО стенда: 01 → 02 → 03 → 04 → 05 → 09 → 26 → 27.
--  ⚠ НА ЖИВОЙ БАЗЕ (контент отредактирован владельцем) baseline НЕ
--  перезапускать — модель F21: живая база получает только инкременты ≥ 26.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Префлайт: все таблицы должны существовать (скрипт 01 выполнен)
-- ----------------------------------------------------------------------------
do $$
declare
    t text;
begin
    foreach t in array array[
        'brands',
        'categories',
        'products',
        'product_variants',
        'site_content',
        'order_statuses',
        'status_transitions',
        'payment_methods',
        'delivery_methods',
        'orders',
        'order_items',
        'deliveries',
        'order_status_history',
        'admin_users',
        'promo_codes',
        'looks',
        'look_items',
        'brand_colors',
        'brand_templates',
        'clients',
        'return_reasons',
        'return_requests'
    ] loop
        if to_regclass('public.' || t) is null then
            raise exception 'Sisku draft: не найдена таблица % (скрипт 02). Сначала выполните скрипт 01 и проверьте переключатель проектов Supabase: нужен sisku-draft.', t;
        end if;
    end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Политики (группировка по таблицам; чтение каталога и справочников
--    публичное — using (true) (фикс F09/V4); draft-anon-CRUD — осознанная
--    граница черновика (SECURITY.md §3); запись заявок на возврат — только
--    через RPC (прямых политик нет); удаление причин возврата — только
--    деактивацией (DELETE-политики нет)
-- ----------------------------------------------------------------------------
drop policy if exists anon_read_brands on public.brands;
create policy anon_read_brands on public.brands
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_delete_brands on public.brands;
create policy draft_anon_delete_brands on public.brands
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_brands on public.brands;
create policy draft_anon_insert_brands on public.brands
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_brands on public.brands;
create policy draft_anon_update_brands on public.brands
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_categories on public.categories;
create policy anon_read_categories on public.categories
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_delete_categories on public.categories;
create policy draft_anon_delete_categories on public.categories
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_categories on public.categories;
create policy draft_anon_insert_categories on public.categories
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_categories on public.categories;
create policy draft_anon_update_categories on public.categories
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_products on public.products;
create policy anon_read_products on public.products
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_products on public.products;
create policy draft_anon_insert_products on public.products
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_products on public.products;
create policy draft_anon_update_products on public.products
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_variants on public.product_variants;
create policy anon_read_variants on public.product_variants
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_delete_variants on public.product_variants;
create policy draft_anon_delete_variants on public.product_variants
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_variants on public.product_variants;
create policy draft_anon_insert_variants on public.product_variants
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_variants on public.product_variants;
create policy draft_anon_update_variants on public.product_variants
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_site_content on public.site_content;
create policy anon_read_site_content on public.site_content
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_update_site_content on public.site_content;
create policy draft_anon_update_site_content on public.site_content
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_statuses on public.order_statuses;
create policy anon_read_statuses on public.order_statuses
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists anon_read_transitions on public.status_transitions;
create policy anon_read_transitions on public.status_transitions
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists anon_read_payment_methods on public.payment_methods;
create policy anon_read_payment_methods on public.payment_methods
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_delete_payment_methods on public.payment_methods;
create policy draft_anon_delete_payment_methods on public.payment_methods
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_payment_methods on public.payment_methods;
create policy draft_anon_insert_payment_methods on public.payment_methods
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_payment_methods on public.payment_methods;
create policy draft_anon_update_payment_methods on public.payment_methods
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_delivery_methods on public.delivery_methods;
create policy anon_read_delivery_methods on public.delivery_methods
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_delete_delivery_methods on public.delivery_methods;
create policy draft_anon_delete_delivery_methods on public.delivery_methods
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_delivery_methods on public.delivery_methods;
create policy draft_anon_insert_delivery_methods on public.delivery_methods
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_delivery_methods on public.delivery_methods;
create policy draft_anon_update_delivery_methods on public.delivery_methods
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_read_orders on public.orders;
create policy draft_anon_read_orders on public.orders
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_read_order_items on public.order_items;
create policy draft_anon_read_order_items on public.order_items
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_read_deliveries on public.deliveries;
create policy draft_anon_read_deliveries on public.deliveries
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_read_history on public.order_status_history;
create policy draft_anon_read_history on public.order_status_history
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_delete_admin_users on public.admin_users;
create policy draft_anon_delete_admin_users on public.admin_users
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_admin_users on public.admin_users;
create policy draft_anon_insert_admin_users on public.admin_users
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_read_admin_users on public.admin_users;
create policy draft_anon_read_admin_users on public.admin_users
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_update_admin_users on public.admin_users;
create policy draft_anon_update_admin_users on public.admin_users
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_read_promo on public.promo_codes;
create policy draft_anon_read_promo on public.promo_codes
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_update_promo on public.promo_codes;
create policy draft_anon_update_promo on public.promo_codes
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_promo on public.promo_codes;
create policy draft_anon_write_promo on public.promo_codes
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_delete_looks on public.looks;
create policy draft_anon_delete_looks on public.looks
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_read_looks on public.looks;
create policy draft_anon_read_looks on public.looks
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_update_looks on public.looks;
create policy draft_anon_update_looks on public.looks
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_looks on public.looks;
create policy draft_anon_write_looks on public.looks
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_delete_look_items on public.look_items;
create policy draft_anon_delete_look_items on public.look_items
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_read_look_items on public.look_items;
create policy draft_anon_read_look_items on public.look_items
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_update_look_items on public.look_items;
create policy draft_anon_update_look_items on public.look_items
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_look_items on public.look_items;
create policy draft_anon_write_look_items on public.look_items
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_delete_brand_colors on public.brand_colors;
create policy draft_anon_delete_brand_colors on public.brand_colors
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_read_brand_colors on public.brand_colors;
create policy draft_anon_read_brand_colors on public.brand_colors
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_update_brand_colors on public.brand_colors;
create policy draft_anon_update_brand_colors on public.brand_colors
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_brand_colors on public.brand_colors;
create policy draft_anon_write_brand_colors on public.brand_colors
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_delete_brand_templates on public.brand_templates;
create policy draft_anon_delete_brand_templates on public.brand_templates
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_read_brand_templates on public.brand_templates;
create policy draft_anon_read_brand_templates on public.brand_templates
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_update_brand_templates on public.brand_templates;
create policy draft_anon_update_brand_templates on public.brand_templates
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_brand_templates on public.brand_templates;
create policy draft_anon_write_brand_templates on public.brand_templates
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_delete_clients on public.clients;
create policy draft_anon_delete_clients on public.clients
    as permissive
    for delete
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_read_clients on public.clients;
create policy draft_anon_read_clients on public.clients
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_update_clients on public.clients;
create policy draft_anon_update_clients on public.clients
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_clients on public.clients;
create policy draft_anon_write_clients on public.clients
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists anon_read_return_reasons on public.return_reasons;
create policy anon_read_return_reasons on public.return_reasons
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists draft_anon_insert_return_reasons on public.return_reasons;
create policy draft_anon_insert_return_reasons on public.return_reasons
    as permissive
    for insert
    to anon, authenticated
    with check (true);

drop policy if exists draft_anon_update_return_reasons on public.return_reasons;
create policy draft_anon_update_return_reasons on public.return_reasons
    as permissive
    for update
    to anon, authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_read_return_requests on public.return_requests;
create policy draft_anon_read_return_requests on public.return_requests
    as permissive
    for select
    to anon, authenticated
    using (true);


-- ----------------------------------------------------------------------------
-- 2. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_policies where schemaname = 'public')      as policies_ok,     -- ждём 62
    (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'SELECT')                   as select_policies, -- ждём 22
    (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'INSERT')                   as insert_policies, -- ждём 14
    (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'UPDATE')                   as update_policies, -- ждём 15
    (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'DELETE')                   as delete_policies, -- ждём 11
    (select count(*) from pg_policies
      where schemaname = 'public' and tablename = 'return_requests'
        and cmd in ('INSERT','UPDATE','DELETE'))                        as request_write_policies; -- ждём 0 (запись только через RPC)
