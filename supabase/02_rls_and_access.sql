-- ============================================================================
--  SISKU (черновик) — СКРИПТ 02: RLS и доступ — все 72 политики конечного состояния (консолидация v0.21.1)
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

-- 0. Префлайт: все таблицы должны существовать (скрипт 01)
do $$
begin
    if to_regclass('public.admin_users') is null then
        raise exception 'Скрипт 02: таблица admin_users не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.badges') is null then
        raise exception 'Скрипт 02: таблица badges не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.brand_colors') is null then
        raise exception 'Скрипт 02: таблица brand_colors не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.brand_templates') is null then
        raise exception 'Скрипт 02: таблица brand_templates не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.brands') is null then
        raise exception 'Скрипт 02: таблица brands не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.categories') is null then
        raise exception 'Скрипт 02: таблица categories не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.clients') is null then
        raise exception 'Скрипт 02: таблица clients не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.delivery_methods') is null then
        raise exception 'Скрипт 02: таблица delivery_methods не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.inventory_sessions') is null then
        raise exception 'Скрипт 02: таблица inventory_sessions не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.looks') is null then
        raise exception 'Скрипт 02: таблица looks не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.order_statuses') is null then
        raise exception 'Скрипт 02: таблица order_statuses не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.payment_methods') is null then
        raise exception 'Скрипт 02: таблица payment_methods не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.promo_codes') is null then
        raise exception 'Скрипт 02: таблица promo_codes не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.return_reasons') is null then
        raise exception 'Скрипт 02: таблица return_reasons не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.site_content') is null then
        raise exception 'Скрипт 02: таблица site_content не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.writeoff_reasons') is null then
        raise exception 'Скрипт 02: таблица writeoff_reasons не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.client_contact_history') is null then
        raise exception 'Скрипт 02: таблица client_contact_history не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.client_name_history') is null then
        raise exception 'Скрипт 02: таблица client_name_history не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.orders') is null then
        raise exception 'Скрипт 02: таблица orders не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.products') is null then
        raise exception 'Скрипт 02: таблица products не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.status_transitions') is null then
        raise exception 'Скрипт 02: таблица status_transitions не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.deliveries') is null then
        raise exception 'Скрипт 02: таблица deliveries не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.order_status_history') is null then
        raise exception 'Скрипт 02: таблица order_status_history не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.product_badges') is null then
        raise exception 'Скрипт 02: таблица product_badges не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.product_variants') is null then
        raise exception 'Скрипт 02: таблица product_variants не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.return_requests') is null then
        raise exception 'Скрипт 02: таблица return_requests не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.inventory_items') is null then
        raise exception 'Скрипт 02: таблица inventory_items не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.look_items') is null then
        raise exception 'Скрипт 02: таблица look_items не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.order_items') is null then
        raise exception 'Скрипт 02: таблица order_items не найдена — сначала выполните 01_schema.sql';
    end if;
    if to_regclass('public.writeoffs') is null then
        raise exception 'Скрипт 02: таблица writeoffs не найдена — сначала выполните 01_schema.sql';
    end if;
end
$$;

-- 1. Политики (72; сгенерированы из конечного состояния каталога)
drop policy if exists draft_anon_delete_admin_users on public.admin_users;
create policy draft_anon_delete_admin_users on public.admin_users
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_admin_users on public.admin_users;
create policy draft_anon_insert_admin_users on public.admin_users
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_read_admin_users on public.admin_users;
create policy draft_anon_read_admin_users on public.admin_users
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_admin_users on public.admin_users;
create policy draft_anon_update_admin_users on public.admin_users
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_badges on public.badges;
create policy anon_read_badges on public.badges
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_badges on public.badges;
create policy draft_anon_insert_badges on public.badges
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_badges on public.badges;
create policy draft_anon_update_badges on public.badges
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_delete_brand_colors on public.brand_colors;
create policy draft_anon_delete_brand_colors on public.brand_colors
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_read_brand_colors on public.brand_colors;
create policy draft_anon_read_brand_colors on public.brand_colors
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_brand_colors on public.brand_colors;
create policy draft_anon_update_brand_colors on public.brand_colors
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_brand_colors on public.brand_colors;
create policy draft_anon_write_brand_colors on public.brand_colors
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_delete_brand_templates on public.brand_templates;
create policy draft_anon_delete_brand_templates on public.brand_templates
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_read_brand_templates on public.brand_templates;
create policy draft_anon_read_brand_templates on public.brand_templates
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_brand_templates on public.brand_templates;
create policy draft_anon_update_brand_templates on public.brand_templates
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_brand_templates on public.brand_templates;
create policy draft_anon_write_brand_templates on public.brand_templates
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists anon_read_brands on public.brands;
create policy anon_read_brands on public.brands
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_delete_brands on public.brands;
create policy draft_anon_delete_brands on public.brands
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_brands on public.brands;
create policy draft_anon_insert_brands on public.brands
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_brands on public.brands;
create policy draft_anon_update_brands on public.brands
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_categories on public.categories;
create policy anon_read_categories on public.categories
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_delete_categories on public.categories;
create policy draft_anon_delete_categories on public.categories
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_categories on public.categories;
create policy draft_anon_insert_categories on public.categories
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_categories on public.categories;
create policy draft_anon_update_categories on public.categories
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_delete_clients on public.clients;
create policy draft_anon_delete_clients on public.clients
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_read_clients on public.clients;
create policy draft_anon_read_clients on public.clients
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_clients on public.clients;
create policy draft_anon_update_clients on public.clients
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_clients on public.clients;
create policy draft_anon_write_clients on public.clients
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_read_deliveries on public.deliveries;
create policy draft_anon_read_deliveries on public.deliveries
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists anon_read_delivery_methods on public.delivery_methods;
create policy anon_read_delivery_methods on public.delivery_methods
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_delete_delivery_methods on public.delivery_methods;
create policy draft_anon_delete_delivery_methods on public.delivery_methods
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_delivery_methods on public.delivery_methods;
create policy draft_anon_insert_delivery_methods on public.delivery_methods
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_delivery_methods on public.delivery_methods;
create policy draft_anon_update_delivery_methods on public.delivery_methods
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_delete_look_items on public.look_items;
create policy draft_anon_delete_look_items on public.look_items
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_read_look_items on public.look_items;
create policy draft_anon_read_look_items on public.look_items
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_look_items on public.look_items;
create policy draft_anon_update_look_items on public.look_items
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_look_items on public.look_items;
create policy draft_anon_write_look_items on public.look_items
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_delete_looks on public.looks;
create policy draft_anon_delete_looks on public.looks
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_read_looks on public.looks;
create policy draft_anon_read_looks on public.looks
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_looks on public.looks;
create policy draft_anon_update_looks on public.looks
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_looks on public.looks;
create policy draft_anon_write_looks on public.looks
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_read_order_items on public.order_items;
create policy draft_anon_read_order_items on public.order_items
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_read_history on public.order_status_history;
create policy draft_anon_read_history on public.order_status_history
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists anon_read_statuses on public.order_statuses;
create policy anon_read_statuses on public.order_statuses
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_read_orders on public.orders;
create policy draft_anon_read_orders on public.orders
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists anon_read_payment_methods on public.payment_methods;
create policy anon_read_payment_methods on public.payment_methods
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_delete_payment_methods on public.payment_methods;
create policy draft_anon_delete_payment_methods on public.payment_methods
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_payment_methods on public.payment_methods;
create policy draft_anon_insert_payment_methods on public.payment_methods
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_payment_methods on public.payment_methods;
create policy draft_anon_update_payment_methods on public.payment_methods
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_delete_product_badges on public.product_badges;
create policy draft_anon_delete_product_badges on public.product_badges
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_product_badges on public.product_badges;
create policy draft_anon_insert_product_badges on public.product_badges
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_read_product_badges on public.product_badges;
create policy draft_anon_read_product_badges on public.product_badges
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_product_badges on public.product_badges;
create policy draft_anon_update_product_badges on public.product_badges
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_variants on public.product_variants;
create policy anon_read_variants on public.product_variants
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_delete_variants on public.product_variants;
create policy draft_anon_delete_variants on public.product_variants
    as permissive
    for delete
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_variants on public.product_variants;
create policy draft_anon_insert_variants on public.product_variants
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_variants on public.product_variants;
create policy draft_anon_update_variants on public.product_variants
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_products on public.products;
create policy anon_read_products on public.products
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_products on public.products;
create policy draft_anon_insert_products on public.products
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_products on public.products;
create policy draft_anon_update_products on public.products
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_read_promo on public.promo_codes;
create policy draft_anon_read_promo on public.promo_codes
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_promo on public.promo_codes;
create policy draft_anon_update_promo on public.promo_codes
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_write_promo on public.promo_codes;
create policy draft_anon_write_promo on public.promo_codes
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists anon_read_return_reasons on public.return_reasons;
create policy anon_read_return_reasons on public.return_reasons
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_return_reasons on public.return_reasons;
create policy draft_anon_insert_return_reasons on public.return_reasons
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_return_reasons on public.return_reasons;
create policy draft_anon_update_return_reasons on public.return_reasons
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists draft_anon_read_return_requests on public.return_requests;
create policy draft_anon_read_return_requests on public.return_requests
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists anon_read_site_content on public.site_content;
create policy anon_read_site_content on public.site_content
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_update_site_content on public.site_content;
create policy draft_anon_update_site_content on public.site_content
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

drop policy if exists anon_read_transitions on public.status_transitions;
create policy anon_read_transitions on public.status_transitions
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists anon_read_writeoff_reasons on public.writeoff_reasons;
create policy anon_read_writeoff_reasons on public.writeoff_reasons
    as permissive
    for select
    to anon,authenticated
    using (true);

drop policy if exists draft_anon_insert_writeoff_reasons on public.writeoff_reasons;
create policy draft_anon_insert_writeoff_reasons on public.writeoff_reasons
    as permissive
    for insert
    to anon,authenticated
    with check (true);

drop policy if exists draft_anon_update_writeoff_reasons on public.writeoff_reasons;
create policy draft_anon_update_writeoff_reasons on public.writeoff_reasons
    as permissive
    for update
    to anon,authenticated
    using (true)
    with check (true);

-- ----------------------------------------------------------------------------
-- 2. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_policies where schemaname = 'public')           as policies_72,  -- ждём 72
    (select count(*) from pg_policies where schemaname = 'public' and cmd = 'SELECT')  as sel,   -- ждём 25
    (select count(*) from pg_policies where schemaname = 'public' and cmd = 'INSERT')  as ins,   -- ждём 17
    (select count(*) from pg_policies where schemaname = 'public' and cmd = 'UPDATE')  as upd,   -- ждём 18
    (select count(*) from pg_policies where schemaname = 'public' and cmd = 'DELETE')  as del,   -- ждём 12
    (select count(*) from pg_policies where schemaname = 'public'
      and tablename in ('return_requests') and cmd in ('INSERT','UPDATE','DELETE'))    as rr_direct_write; -- ждём 0
-- Ожидаемая строка самопроверки (psql -At): 72|25|17|18|12|0
