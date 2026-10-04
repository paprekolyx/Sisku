-- ============================================================================
--  SISKU (черновик) — СКРИПТ 12: управление справочниками и текстами сайта
-- ============================================================================
--  Открывает anon-запись для страниц раздела «Управление» и «Бренды»:
--    brands           — insert / update / delete (CRUD брендов);
--    delivery_methods — insert / update (цены и активность способов доставки);
--    payment_methods  — insert / update (способы оплаты);
--    site_content     — update (правка текстов сайта из админки).
--  Черновое допущение, как и прочие draft_anon_*: в боевой версии всё это
--  пишется только авторизованным API с ролями (migration-plan.md, M2).
--  Удаление способов с заказами заблокирует FK — это штатная защита.
--  Идемпотентен.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: стоим в проекте черновика Sisku
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.brands') is null
       or to_regclass('public.site_content') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (brands / site_content). Проверьте переключатель проектов Supabase: нужен sisku-draft.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Бренды
-- ----------------------------------------------------------------------------
drop policy if exists draft_anon_insert_brands on public.brands;
create policy draft_anon_insert_brands on public.brands
    for insert to anon, authenticated with check (true);

drop policy if exists draft_anon_update_brands on public.brands;
create policy draft_anon_update_brands on public.brands
    for update to anon, authenticated using (true) with check (true);

drop policy if exists draft_anon_delete_brands on public.brands;
create policy draft_anon_delete_brands on public.brands
    for delete to anon, authenticated using (true);   -- FK не даст удалить бренд с товарами

-- ----------------------------------------------------------------------------
-- 2. Способы доставки и оплаты
-- ----------------------------------------------------------------------------
drop policy if exists draft_anon_insert_delivery_methods on public.delivery_methods;
create policy draft_anon_insert_delivery_methods on public.delivery_methods
    for insert to anon, authenticated with check (true);

drop policy if exists draft_anon_update_delivery_methods on public.delivery_methods;
create policy draft_anon_update_delivery_methods on public.delivery_methods
    for update to anon, authenticated using (true) with check (true);

drop policy if exists draft_anon_insert_payment_methods on public.payment_methods;
create policy draft_anon_insert_payment_methods on public.payment_methods
    for insert to anon, authenticated with check (true);

drop policy if exists draft_anon_update_payment_methods on public.payment_methods;
create policy draft_anon_update_payment_methods on public.payment_methods
    for update to anon, authenticated using (true) with check (true);

-- ----------------------------------------------------------------------------
-- 3. Тексты сайта
-- ----------------------------------------------------------------------------
drop policy if exists draft_anon_update_site_content on public.site_content;
create policy draft_anon_update_site_content on public.site_content
    for update to anon, authenticated using (true) with check (true);

-- ----------------------------------------------------------------------------
-- 4. Самопроверка: ожидаем 8 политик записи — ровно те, что создаёт
--    этот скрипт (фикс F19: комментарий обещал 9, а список draft_anon_* на этих
--    таблицах с v0.14.0 вообще равен 10 — скрипт 16 добавляет DELETE для
--    delivery_methods/payment_methods; поэтому считаем явный список).
-- ----------------------------------------------------------------------------
select count(*) as write_policies
from pg_policies
where policyname in (
    'draft_anon_insert_brands', 'draft_anon_update_brands', 'draft_anon_delete_brands',
    'draft_anon_insert_delivery_methods', 'draft_anon_update_delivery_methods',
    'draft_anon_insert_payment_methods', 'draft_anon_update_payment_methods',
    'draft_anon_update_site_content'
);
