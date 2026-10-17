-- ============================================================================
--  SISKU (черновик) — СКРИПТ 05: посев каталога конечного состояния (консолидация v0.21.1; альтернатива импорту CSV)
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

-- Демонстрационный каталог (8 товаров, 20 вариантов); «Тестовый товар»
-- владельца (00001) — данные живой базы, в посев не входят

-- ---------- brands ----------
insert into public.brands (id, name, country, is_active) values (1, 'Aurelle', 'Франция', 'true') on conflict do nothing;
insert into public.brands (id, name, country, is_active) values (2, 'Maison Nord', 'Швеция', 'true') on conflict do nothing;
insert into public.brands (id, name, country, is_active) values (3, 'Verte Studio', 'Италия', 'true') on conflict do nothing;
insert into public.brands (id, name, country, is_active) values (4, 'Ombre', 'Франция', 'true') on conflict do nothing;
insert into public.brands (id, name, country, is_active) values (5, 'Lumière', 'Франция', 'true') on conflict do nothing;
insert into public.brands (id, name, country, is_active) values (6, 'Atelier 9', 'Россия', 'true') on conflict do nothing;
select setval(pg_get_serial_sequence('public.brands', 'id'), (select coalesce(max(id), 1) from public.brands));

-- ---------- categories ----------
insert into public.categories (id, slug, name, description) values (1, 'verhnyaya-odezhda', 'Верхняя одежда', 'Пальто и плащи из шерсти и кашемира') on conflict do nothing;
insert into public.categories (id, slug, name, description) values (2, 'platya', 'Платья', 'Шёлк и костюмные ткани') on conflict do nothing;
insert into public.categories (id, slug, name, description) values (3, 'trikotazh', 'Трикотаж', 'Кашемир и мериносовая шерсть') on conflict do nothing;
insert into public.categories (id, slug, name, description) values (4, 'rubashki', 'Рубашки и блузы', 'Хлопок и поплин') on conflict do nothing;
insert into public.categories (id, slug, name, description) values (5, 'parfyumeriya', 'Парфюмерия', 'Нишевые ароматы и классика домов') on conflict do nothing;
insert into public.categories (id, slug, name, description) values (6, 'aksessuary', 'Аксессуары', 'Шёлк и кожа') on conflict do nothing;
select setval(pg_get_serial_sequence('public.categories', 'id'), (select coalesce(max(id), 1) from public.categories));

-- ---------- products ----------
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) values (1, '10001', 'Пальто Nordline из шерсти и кашемира', '48900.00', '2', '1', 'Двубортное пальто свободного кроя с поясом. Состав: шерсть 80% и кашемир 20%. Подкладка из вискозы. Длина миди.', 'assets/img/products/p001.webp', 'true', '2026-10-06 21:43:10.127189+00') on conflict do nothing;
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) values (2, '10002', 'Платье Aurelle Soie из шёлка', '32500.00', '1', '2', 'Платье-комбинация из плотного шёлка с драпировкой на спине и регулируемыми бретелями.', 'assets/img/products/p002.webp', 'true', '2026-10-06 21:43:10.127189+00') on conflict do nothing;
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) values (3, '10003', 'Свитер Verte Cashmere', '21900.00', '3', '3', 'Свитер из монгольского кашемира. Высокое горло и спущенное плечо. Плотная резинка.', 'assets/img/products/p003.webp', 'true', '2026-10-06 21:43:10.127189+00') on conflict do nothing;
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) values (4, '10004', 'Рубашка Atelier 9 из хлопка', '14500.00', '6', '4', 'Оверсайз-рубашка из плотного хлопкового поплина со скрытой планкой и удлинённой спинкой.', 'assets/img/products/p004.webp', 'true', '2026-10-06 21:43:10.127189+00') on conflict do nothing;
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) values (5, '20001', 'Парфюм Lumière Fleurale eau de parfum', '17900.00', '5', '5', 'Цветочный аромат: пион и белая роза с магнолией на мускусной базе. Стойкость 6–8 часов.', 'assets/img/products/p005.webp', 'true', '2026-10-06 21:43:10.127189+00') on conflict do nothing;
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) values (6, '20002', 'Парфюм Maison Nord Bois eau de parfum', '19500.00', '2', '5', 'Древесный аромат: кедр и ветивер с серой амброй. Скандинавская сдержанность.', 'assets/img/products/p006.webp', 'true', '2026-10-06 21:43:10.127189+00') on conflict do nothing;
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) values (7, '20003', 'Парфюм Ombre Oud extrait', '27400.00', '4', '5', 'Нишевый экстракт: уд и смолы на кожаной базе. Ограниченная серия с нумерованными флаконами.', 'assets/img/products/p007.webp', 'true', '2026-10-06 21:43:10.127189+00') on conflict do nothing;
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) values (8, '30001', 'Платок Aurelle Carré шёлковый', '9800.00', '1', '6', 'Квадратный платок 90×90 см из шёлка твил с авторским принтом. Края подшиты вручную.', 'assets/img/products/p008.webp', 'true', '2026-10-06 21:43:10.127189+00') on conflict do nothing;
select setval(pg_get_serial_sequence('public.products', 'id'), (select coalesce(max(id), 1) from public.products));

-- ---------- product_variants ----------
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (1, '1', 'XS', '2', '1', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (2, '1', 'S', '3', '2', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (3, '1', 'M', '2', '3', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (4, '1', 'L', '1', '4', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (5, '2', 'XS', '1', '1', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (6, '2', 'S', '2', '2', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (7, '2', 'M', '2', '3', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (8, '3', 'S', '3', '1', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (9, '3', 'M', '4', '2', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (10, '3', 'L', '2', '3', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (11, '3', 'XL', '2', '4', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (12, '4', 'S', '2', '1', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (13, '4', 'M', '2', '2', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (14, '4', 'L', '3', '3', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (15, '5', '50 мл', '5', '1', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (16, '5', '100 мл', '4', '2', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (17, '6', '100 мл', '6', '1', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (18, '7', '50 мл', '3', '1', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (19, '7', '100 мл', '2', '2', '0') on conflict do nothing;
insert into public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) values (20, '8', 'One size', '10', '1', '0') on conflict do nothing;
select setval(pg_get_serial_sequence('public.product_variants', 'id'), (select coalesce(max(id), 1) from public.product_variants));

-- ---------- бейдж «New» — всем товарам (волна v0.21.0, ответ 1.9/Д7) ----------
insert into public.product_badges (product_id, badge_id, sort_order)
select p.id, b.id, 1
  from public.products p
 cross join public.badges b
 where b.code = 'new'
on conflict (product_id, badge_id) do nothing;

-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.brands)                                     as brands_6,    -- ждём 6
    (select count(*) from public.categories)                                 as cats_6,      -- ждём 6
    (select count(*) from public.products)                                   as products_8,  -- ждём 8
    (select count(*) from public.product_variants)                           as variants_20, -- ждём 20
    (select count(*) from public.products where image_url like '%%.jpg')      as jpg_0,       -- ждём 0
    (select (select count(*) from public.product_badges pb
              join public.badges b on b.id = pb.badge_id
             where b.code = 'new')
          = (select count(*) from public.products))                          as new_all;     -- ждём t
-- Ожидаемая строка самопроверки (psql -At): 6|6|8|20|0|t
