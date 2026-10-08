-- ============================================================================
--  SISKU (черновик) — СКРИПТ 27: пути изображений .jpg → .webp (guard)
-- ============================================================================
--  Волна v0.17.0 (07.10.2026) — обработка внешнего ревью 06.10.2026,
--  находка B1 (приоритет №2): изображения витрины переводятся в WebP
--  (~48 МБ → ≤5 МБ); файлы assets/img/*.jpg заменяются на *.webp в
--  репозитории, этот скрипт выравнивает пути В ДАННЫХ:
--    (1) products.image_url — только точный демо-шаблон
--        'assets/img/products/pNNN.jpg' (8 строк посева; пользовательские
--        пути и dataURL не затрагиваются — «Тестовый товар» 00001 без
--        image_url остаётся как есть);
--    (2) site_content — замена 10 известных путей (hero, hero-dark, p001–
--        p008) в значениях любых ключей (about.img.dark и будущие); guard —
--        только строки, содержащие старый путь (сейчас значение пустое —
--        no-op); updated_at обновляется (паттерн скрипта 25).
--  ⚠ ОДНОРАЗОВАЯ data-миграция с guard по старому значению (культура F21/
--  скрипта 25): повторный прогон безопасен (старых путей уже нет — no-op),
--  но по регламенту выполняется один раз. На живой базе затрагивает только
--  строки с демо-путями .jpg.
--  Идемпотентен (guard). Порядок: после baseline 01–09 и скрипта 26.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. products.image_url: демо-пути .jpg → .webp (guard по шаблону)
-- ----------------------------------------------------------------------------
update public.products
   set image_url = substr(image_url, 1, length(image_url) - 4) || '.webp'
 where image_url like 'assets/img/products/%.jpg';

-- ----------------------------------------------------------------------------
-- 2. site_content: известные пути изображений в значениях ключей
-- ----------------------------------------------------------------------------
do $$
declare
    m text[];
begin
    foreach m slice 1 in array array[
        ('assets/img/hero-dark.jpg', 'assets/img/hero-dark.webp'),
        ('assets/img/hero.jpg', 'assets/img/hero.webp'),
        ('assets/img/products/p001.jpg', 'assets/img/products/p001.webp'),
        ('assets/img/products/p002.jpg', 'assets/img/products/p002.webp'),
        ('assets/img/products/p003.jpg', 'assets/img/products/p003.webp'),
        ('assets/img/products/p004.jpg', 'assets/img/products/p004.webp'),
        ('assets/img/products/p005.jpg', 'assets/img/products/p005.webp'),
        ('assets/img/products/p006.jpg', 'assets/img/products/p006.webp'),
        ('assets/img/products/p007.jpg', 'assets/img/products/p007.webp'),
        ('assets/img/products/p008.jpg', 'assets/img/products/p008.webp')
    ] loop
        update public.site_content
           set value      = replace(value, m[1], m[2]),
               updated_at = now()
         where position(m[1] in value) > 0;
    end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 3. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.products
      where image_url like 'assets/img/products/%.webp')             as products_webp,      -- ждём 8 (свежий стенд; живая база — фактическое число демо-товаров)
    (select count(*) from public.products
      where image_url like '%.jpg')                                   as products_jpg_left,  -- ждём 0
    (select count(*) from public.site_content
      where value like '%assets/img/%.jpg%')                         as content_jpg_left;   -- ждём 0
