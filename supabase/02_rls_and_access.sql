-- ============================================================================
--  SISKU (черновик) — СКРИПТ 2: политики RLS (кто и что может читать)
-- ============================================================================
--  ПУБЛИЧНОЕ ЧТЕНИЕ (роль anon, то есть любой посетитель сайта):
--    brands, categories, products, product_variants, site_content,
--    order_statuses            — всё;
--    payment_methods, delivery_methods — только активные (is_active = true).
--
--  СОЗНАТЕЛЬНОЕ УПРОЩЕНИЕ ЧЕРНОВИКА (перенесено из «недостатков» учебного
--  проекта по решению заказчика): заказы читаются анонимно, потому что
--  админ-панель макета открывается по ссылке без пароля.
--    orders, order_items, deliveries, order_status_history — SELECT для anon.
--  Это НЕ модель для боевой версии: там заказы закрываются, а доступ
--  получают только авторизованные роли (см. отчёт по проекту, п. 1.7).
--
--  ЗАПИСЬ (на момент этого скрипта): прямого INSERT/UPDATE/DELETE из браузера
--    нет. Заказ создаётся только функцией create_order() (скрипт 03),
--    статусы и оплата меняются только admin_set_status() / admin_set_paid().
--    ВНИМАНИЕ: в последующих скриптах (07, 09–16) для админки черновика
--    появляются draft_anon_*-политики записи на каталог, справочники,
--    промокоды, луки, брендбук и клиентов — полный перечень и границы
--    см. в SECURITY.md §2 (правка v0.14.0 по ревью F04: формулировка
--    «запись закрыта полностью» устарела ещё в v0.4.0).
--
--  Скрипт идемпотентен: drop policy if exists перед create policy.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: убеждаемся, что мы в проекте черновика Sisku, а не в учебном
--    (правило 6 supabase/README.md; добавлен в v0.14.0 по ревью F20 —
--    префлайт обязателен для всех скриптов, создающих политики).
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.product_variants') is null
       or to_regclass('public.site_content') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (product_variants / site_content). Проверьте переключатель проектов Supabase слева вверху: нужен проект sisku-draft, а не учебный. Сначала выполните скрипт 01.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Публичное чтение каталога и текстов
-- ----------------------------------------------------------------------------
drop policy if exists anon_read_brands on public.brands;
create policy anon_read_brands on public.brands
    for select to anon, authenticated using (true);

drop policy if exists anon_read_categories on public.categories;
create policy anon_read_categories on public.categories
    for select to anon, authenticated using (true);

drop policy if exists anon_read_products on public.products;
create policy anon_read_products on public.products
    for select to anon, authenticated using (true);

drop policy if exists anon_read_variants on public.product_variants;
create policy anon_read_variants on public.product_variants
    for select to anon, authenticated using (true);

drop policy if exists anon_read_site_content on public.site_content;
create policy anon_read_site_content on public.site_content
    for select to anon, authenticated using (true);

drop policy if exists anon_read_statuses on public.order_statuses;
create policy anon_read_statuses on public.order_statuses
    for select to anon, authenticated using (true);

-- модель переходов статусов нужна админке для кнопок смены статуса
drop policy if exists anon_read_transitions on public.status_transitions;
create policy anon_read_transitions on public.status_transitions
    for select to anon, authenticated using (true);

drop policy if exists anon_read_payment_methods on public.payment_methods;
create policy anon_read_payment_methods on public.payment_methods
    for select to anon, authenticated using (is_active = true);

drop policy if exists anon_read_delivery_methods on public.delivery_methods;
create policy anon_read_delivery_methods on public.delivery_methods
    for select to anon, authenticated using (is_active = true);

-- ----------------------------------------------------------------------------
-- 2. Черновик: заказы читаются анонимно (админка без пароля, доступ по ссылке)
-- ----------------------------------------------------------------------------
drop policy if exists draft_anon_read_orders on public.orders;
create policy draft_anon_read_orders on public.orders
    for select to anon, authenticated using (true);

drop policy if exists draft_anon_read_order_items on public.order_items;
create policy draft_anon_read_order_items on public.order_items
    for select to anon, authenticated using (true);

drop policy if exists draft_anon_read_deliveries on public.deliveries;
create policy draft_anon_read_deliveries on public.deliveries
    for select to anon, authenticated using (true);

drop policy if exists draft_anon_read_history on public.order_status_history;
create policy draft_anon_read_history on public.order_status_history
    for select to anon, authenticated using (true);

-- ----------------------------------------------------------------------------
-- 3. Политик на запись НЕТ: все изменения — только через функции скрипта 03.
-- ----------------------------------------------------------------------------
