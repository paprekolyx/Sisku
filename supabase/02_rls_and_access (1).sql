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
--  ЗАПИСЬ: прямого INSERT/UPDATE/DELETE из браузера нет НИГДЕ.
--    Заказ создаётся только функцией create_order() (скрипт 03),
--    статусы и оплата меняются только admin_set_status() / admin_set_paid().
--    Таблицы при этом остаются закрыты для записи: функции security definer.
--
--  Скрипт идемпотентен: drop policy if exists перед create policy.
-- ============================================================================

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
