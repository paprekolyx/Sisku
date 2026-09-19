-- ============================================================================
--  SISKU (черновик) — СКРИПТ 5 (ЗАПАСНОЙ): посев каталога без CSV
-- ============================================================================
--  ЗАЧЕМ: если импорт CSV в Table Editor ругается или даёт сдвиг столбцов —
--  этот скрипт заполняет brands, categories, products, product_variants
--  одним нажатием Run, без участия CSV-парсера.
--
--  КАК ИСПОЛЬЗОВАТЬ: либо импорт CSV (brands → categories → products →
--  variants), либо этот скрипт. НЕ ОБА СРАЗУ: вставки идемпотентны
--  (on conflict do nothing), но если CSV уже частично загружен — сначала
--  очистить таблицы truncate-запросом из docs/setup-supabase.md.
--
--  Id задаются явно (1…N), чтобы совпасть с product_id в вариантах;
--  в конце sequence выставляются на максимум — следующие импорты/вставки
--  продолжат нумерацию правильно.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Бренды
-- ----------------------------------------------------------------------------
insert into public.brands (id, name, country, is_active) values
    (1, 'Aurelle',      'Франция', true),
    (2, 'Maison Nord',  'Швеция',  true),
    (3, 'Verte Studio', 'Италия',  true),
    (4, 'Ombre',        'Франция', true),
    (5, 'Lumière',      'Франция', true),
    (6, 'Atelier 9',    'Россия',  true)
on conflict (id) do nothing;
select setval(pg_get_serial_sequence('public.brands', 'id'), coalesce(max(id), 1)) from public.brands;

-- ----------------------------------------------------------------------------
-- 2. Категории
-- ----------------------------------------------------------------------------
insert into public.categories (id, slug, name, description) values
    (1, 'verhnyaya-odezhda', 'Верхняя одежда',  'Пальто и плащи из шерсти и кашемира'),
    (2, 'platya',            'Платья',          'Шёлк и костюмные ткани'),
    (3, 'trikotazh',         'Трикотаж',        'Кашемир и мериносовая шерсть'),
    (4, 'rubashki',          'Рубашки и блузы', 'Хлопок и поплин'),
    (5, 'parfyumeriya',      'Парфюмерия',      'Нишевые ароматы и классика домов'),
    (6, 'aksessuary',        'Аксессуары',      'Шёлк и кожа')
on conflict (id) do nothing;
select setval(pg_get_serial_sequence('public.categories', 'id'), coalesce(max(id), 1)) from public.categories;

-- ----------------------------------------------------------------------------
-- 3. Товары (id явные — на них ссылаются варианты ниже)
-- ----------------------------------------------------------------------------
insert into public.products (id, article, name, price, brand_id, category_id, description, image_url, is_active) values
    (1, '10001', 'Пальто Nordline из шерсти и кашемира',   48900.00, 2, 1, 'Двубортное пальто свободного кроя с поясом. Состав: шерсть 80% и кашемир 20%. Подкладка из вискозы. Длина миди.', 'assets/img/products/p001.jpg', true),
    (2, '10002', 'Платье Aurelle Soie из шёлка',           32500.00, 1, 2, 'Платье-комбинация из плотного шёлка с драпировкой на спине и регулируемыми бретелями.',                          'assets/img/products/p002.jpg', true),
    (3, '10003', 'Свитер Verte Cashmere',                  21900.00, 3, 3, 'Свитер из монгольского кашемира. Высокое горло и спущенное плечо. Плотная резинка.',                              'assets/img/products/p003.jpg', true),
    (4, '10004', 'Рубашка Atelier 9 из хлопка',            14500.00, 6, 4, 'Оверсайз-рубашка из плотного хлопкового поплина со скрытой планкой и удлинённой спинкой.',                        'assets/img/products/p004.jpg', true),
    (5, '20001', 'Парфюм Lumière Fleurale eau de parfum',  17900.00, 5, 5, 'Цветочный аромат: пион и белая роза с магнолией на мускусной базе. Стойкость 6–8 часов.',                        'assets/img/products/p005.jpg', true),
    (6, '20002', 'Парфюм Maison Nord Bois eau de parfum',  19500.00, 2, 5, 'Древесный аромат: кедр и ветивер с серой амброй. Скандинавская сдержанность.',                                  'assets/img/products/p006.jpg', true),
    (7, '20003', 'Парфюм Ombre Oud extrait',               27400.00, 4, 5, 'Нишевый экстракт: уд и смолы на кожаной базе. Ограниченная серия с нумерованными флаконами.',                    'assets/img/products/p007.jpg', true),
    (8, '30001', 'Платок Aurelle Carré шёлковый',           9800.00, 1, 6, 'Квадратный платок 90×90 из шёлка твил с авторским принтом. Края подшиты вручную.',                              'assets/img/products/p008.jpg', true)
on conflict (id) do nothing;
select setval(pg_get_serial_sequence('public.products', 'id'), coalesce(max(id), 1)) from public.products;

-- ----------------------------------------------------------------------------
-- 4. Варианты (размеры / объёмы + остатки)
-- ----------------------------------------------------------------------------
insert into public.product_variants (id, product_id, label, stock, sort_order) values
    (1,  1, 'XS',      2, 1),
    (2,  1, 'S',       3, 2),
    (3,  1, 'M',       2, 3),
    (4,  1, 'L',       1, 4),
    (5,  2, 'XS',      1, 1),
    (6,  2, 'S',       2, 2),
    (7,  2, 'M',       2, 3),
    (8,  3, 'S',       3, 1),
    (9,  3, 'M',       4, 2),
    (10, 3, 'L',       2, 3),
    (11, 3, 'XL',      2, 4),
    (12, 4, 'S',       2, 1),
    (13, 4, 'M',       2, 2),
    (14, 4, 'L',       3, 3),
    (15, 5, '50 мл',   5, 1),
    (16, 5, '100 мл',  4, 2),
    (17, 6, '100 мл',  6, 1),
    (18, 7, '50 мл',   3, 1),
    (19, 7, '100 мл',  2, 2),
    (20, 8, 'One size',10, 1)
on conflict (id) do nothing;
select setval(pg_get_serial_sequence('public.product_variants', 'id'), coalesce(max(id), 1)) from public.product_variants;

-- Проверка: должно вывести 6 / 6 / 8 / 20
select
    (select count(*) from public.brands)           as brands,
    (select count(*) from public.categories)       as categories,
    (select count(*) from public.products)         as products,
    (select count(*) from public.product_variants) as variants;
