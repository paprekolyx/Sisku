-- ============================================================================
--  SISKU (черновик) — СКРИПТ 05: запасной посев каталога без CSV — конечное состояние на v0.16.0
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE (волна v0.17.0, 07.10.2026): состояние базы на
--  v0.16.0-draft одним скриптом. Заменяет исторические скрипты 05, 08 (описание товара 30001 исправлено в посеве).
--  Исторические версии (включая промежуточные версии функций) — замороженный
--  архив supabase/archive/sql-01-25-v0160.md и git-история; номера удалённых
--  скриптов не переиспользуются (SQL-регламент).
--  Идемпотентен: insert … on conflict do nothing; id задаются явно, в конце sequence выставляются на максимум.
--  Порядок для НОВОГО стенда: 01 → 02 → 03 → 04 → 05 → 09 → 26 → 27.
--  ⚠ НА ЖИВОЙ БАЗЕ (контент отредактирован владельцем) baseline НЕ
--  перезапускать — модель F21: живая база получает только инкременты ≥ 26.
-- ============================================================================


-- ---------- brands (6 стр.) ----------

INSERT INTO public.brands (id, name, country, is_active) VALUES (1, 'Aurelle', 'Франция', true) on conflict do nothing;

INSERT INTO public.brands (id, name, country, is_active) VALUES (2, 'Maison Nord', 'Швеция', true) on conflict do nothing;

INSERT INTO public.brands (id, name, country, is_active) VALUES (3, 'Verte Studio', 'Италия', true) on conflict do nothing;

INSERT INTO public.brands (id, name, country, is_active) VALUES (4, 'Ombre', 'Франция', true) on conflict do nothing;

INSERT INTO public.brands (id, name, country, is_active) VALUES (5, 'Lumière', 'Франция', true) on conflict do nothing;

INSERT INTO public.brands (id, name, country, is_active) VALUES (6, 'Atelier 9', 'Россия', true) on conflict do nothing;

SELECT pg_catalog.setval('public.brands_id_seq', 6, true);


-- ---------- categories (6 стр.) ----------

INSERT INTO public.categories (id, slug, name, description) VALUES (1, 'verhnyaya-odezhda', 'Верхняя одежда', 'Пальто и плащи из шерсти и кашемира') on conflict do nothing;

INSERT INTO public.categories (id, slug, name, description) VALUES (2, 'platya', 'Платья', 'Шёлк и костюмные ткани') on conflict do nothing;

INSERT INTO public.categories (id, slug, name, description) VALUES (3, 'trikotazh', 'Трикотаж', 'Кашемир и мериносовая шерсть') on conflict do nothing;

INSERT INTO public.categories (id, slug, name, description) VALUES (4, 'rubashki', 'Рубашки и блузы', 'Хлопок и поплин') on conflict do nothing;

INSERT INTO public.categories (id, slug, name, description) VALUES (5, 'parfyumeriya', 'Парфюмерия', 'Нишевые ароматы и классика домов') on conflict do nothing;

INSERT INTO public.categories (id, slug, name, description) VALUES (6, 'aksessuary', 'Аксессуары', 'Шёлк и кожа') on conflict do nothing;

SELECT pg_catalog.setval('public.categories_id_seq', 6, true);


-- ---------- products (8 стр.) ----------

INSERT INTO public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) VALUES (1, '10001', 'Пальто Nordline из шерсти и кашемира', 48900.00, 2, 1, 'Двубортное пальто свободного кроя с поясом. Состав: шерсть 80% и кашемир 20%. Подкладка из вискозы. Длина миди.', 'assets/img/products/p001.jpg', true, '2026-10-06 21:43:10.127189+00') on conflict do nothing;

INSERT INTO public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) VALUES (2, '10002', 'Платье Aurelle Soie из шёлка', 32500.00, 1, 2, 'Платье-комбинация из плотного шёлка с драпировкой на спине и регулируемыми бретелями.', 'assets/img/products/p002.jpg', true, '2026-10-06 21:43:10.127189+00') on conflict do nothing;

INSERT INTO public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) VALUES (3, '10003', 'Свитер Verte Cashmere', 21900.00, 3, 3, 'Свитер из монгольского кашемира. Высокое горло и спущенное плечо. Плотная резинка.', 'assets/img/products/p003.jpg', true, '2026-10-06 21:43:10.127189+00') on conflict do nothing;

INSERT INTO public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) VALUES (4, '10004', 'Рубашка Atelier 9 из хлопка', 14500.00, 6, 4, 'Оверсайз-рубашка из плотного хлопкового поплина со скрытой планкой и удлинённой спинкой.', 'assets/img/products/p004.jpg', true, '2026-10-06 21:43:10.127189+00') on conflict do nothing;

INSERT INTO public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) VALUES (5, '20001', 'Парфюм Lumière Fleurale eau de parfum', 17900.00, 5, 5, 'Цветочный аромат: пион и белая роза с магнолией на мускусной базе. Стойкость 6–8 часов.', 'assets/img/products/p005.jpg', true, '2026-10-06 21:43:10.127189+00') on conflict do nothing;

INSERT INTO public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) VALUES (6, '20002', 'Парфюм Maison Nord Bois eau de parfum', 19500.00, 2, 5, 'Древесный аромат: кедр и ветивер с серой амброй. Скандинавская сдержанность.', 'assets/img/products/p006.jpg', true, '2026-10-06 21:43:10.127189+00') on conflict do nothing;

INSERT INTO public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) VALUES (7, '20003', 'Парфюм Ombre Oud extrait', 27400.00, 4, 5, 'Нишевый экстракт: уд и смолы на кожаной базе. Ограниченная серия с нумерованными флаконами.', 'assets/img/products/p007.jpg', true, '2026-10-06 21:43:10.127189+00') on conflict do nothing;

INSERT INTO public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active, created_at) VALUES (8, '30001', 'Платок Aurelle Carré шёлковый', 9800.00, 1, 6, 'Квадратный платок 90×90 см из шёлка твил с авторским принтом. Края подшиты вручную.', 'assets/img/products/p008.jpg', true, '2026-10-06 21:43:10.127189+00') on conflict do nothing;

SELECT pg_catalog.setval('public.products_id_seq', 8, true);


-- ---------- product_variants (20 стр.) ----------

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (1, 1, 'XS', 2, 1, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (2, 1, 'S', 3, 2, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (3, 1, 'M', 2, 3, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (4, 1, 'L', 1, 4, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (5, 2, 'XS', 1, 1, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (6, 2, 'S', 2, 2, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (7, 2, 'M', 2, 3, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (8, 3, 'S', 3, 1, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (9, 3, 'M', 4, 2, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (10, 3, 'L', 2, 3, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (11, 3, 'XL', 2, 4, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (12, 4, 'S', 2, 1, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (13, 4, 'M', 2, 2, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (14, 4, 'L', 3, 3, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (15, 5, '50 мл', 5, 1, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (16, 5, '100 мл', 4, 2, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (17, 6, '100 мл', 6, 1, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (18, 7, '50 мл', 3, 1, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (19, 7, '100 мл', 2, 2, 0) on conflict do nothing;

INSERT INTO public.product_variants (id, product_id, label, stock, sort_order, quarantine_qty) VALUES (20, 8, 'One size', 10, 1, 0) on conflict do nothing;

SELECT pg_catalog.setval('public.product_variants_id_seq', 20, true);


-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.brands)                                as brands_ok,     -- ждём 6
    (select count(*) from public.categories)                            as categories_ok, -- ждём 6
    (select count(*) from public.products)                              as products_ok,   -- ждём 8 (демо-каталог; «Тестовый товар» владельца — данные живой базы, в посев не входят)
    (select count(*) from public.product_variants)                      as variants_ok,   -- ждём 20
    (select count(*) from public.products
      where image_url like 'assets/img/products/%.jpg')                  as jpg_paths;     -- ждём 8 (на v0.16.0; в .webp переводит скрипт 27)
