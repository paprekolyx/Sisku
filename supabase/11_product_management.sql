-- ============================================================================
--  SISKU (черновик) — СКРИПТ 11: управление товарами и категориями из админки
-- ============================================================================
--  Открывает anon-запись (insert/update/delete) для таблиц каталога:
--  products, categories, product_variants — чтобы страницы «Магазин» и
--  «Товары» черновика могли создавать и править карточки без серверного API.
--  Это СОЗНАТЕЛЬНОЕ черновое допущение (как draft_anon_* для заказов):
--  в боевой версии запись каталога идёт только через авторизованный API
--  с ролями (migration-plan.md, волна M2).
--  Чтение остаётся как было; функции create_order/check_promo не меняются.
--  Идемпотентен.
-- ============================================================================

drop policy if exists draft_anon_insert_products on public.products;
create policy draft_anon_insert_products on public.products
    for insert to anon, authenticated with check (true);

drop policy if exists draft_anon_update_products on public.products;
create policy draft_anon_update_products on public.products
    for update to anon, authenticated using (true) with check (true);

drop policy if exists draft_anon_insert_categories on public.categories;
create policy draft_anon_insert_categories on public.categories
    for insert to anon, authenticated with check (true);

drop policy if exists draft_anon_update_categories on public.categories;
create policy draft_anon_update_categories on public.categories
    for update to anon, authenticated using (true) with check (true);

drop policy if exists draft_anon_delete_categories on public.categories;
create policy draft_anon_delete_categories on public.categories
    for delete to anon, authenticated using (true);   -- FK не даст удалить категорию с товарами

drop policy if exists draft_anon_insert_variants on public.product_variants;
create policy draft_anon_insert_variants on public.product_variants
    for insert to anon, authenticated with check (true);

drop policy if exists draft_anon_update_variants on public.product_variants;
create policy draft_anon_update_variants on public.product_variants
    for update to anon, authenticated using (true) with check (true);

drop policy if exists draft_anon_delete_variants on public.product_variants;
create policy draft_anon_delete_variants on public.product_variants
    for delete to anon, authenticated using (true);   -- FK не даст удалить вариант из заказа

-- Самопроверка: политики на месте
select count(*) as write_policies
from pg_policies
where tablename in ('products', 'categories', 'product_variants')
  and policy_name like 'draft_anon_%';   -- ожидаем 8
