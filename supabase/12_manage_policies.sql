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
-- 4. Самопроверка: ожидаем 9 политик записи
-- ----------------------------------------------------------------------------
select count(*) as write_policies
from pg_policies
where tablename in ('brands', 'delivery_methods', 'payment_methods', 'site_content')
  and policy_name like 'draft_anon_%';
