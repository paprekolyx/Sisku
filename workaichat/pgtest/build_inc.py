#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.17.0 — сборка инкрементных скриптов 26 и 27.
26: create_order v8 (лимиты длины ≤1000 — находка ревью C3, решение владельца)
    + check_promo v2 (границы дат в Europe/Moscow — находка C1).
27: guard-миграция путей изображений .jpg → .webp (находка B1, WebP-волна).
Тела функций берутся из эталонной базы sisku_a (v0.16.0) и патчатся программно
(грабля №6 — файлы содержат $: только программные замены + assertions).
Запуск из /home/user: python3 pgtest/build_inc.py → /tmp/baseline/26*.sql, 27*.sql
"""
import os
import subprocess

OUT = '/tmp/baseline'
DB = 'sisku_a'


def psql(query, db=DB):
    r = subprocess.run(['psql', '-d', db, '-At', '-c', query],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[:500]
    return r.stdout


def q(s):
    return "'" + s.replace("'", "''") + "'"


# ---- create_order v8 -------------------------------------------------------
def norm_dq(body, name):
    """$function$ → $$ (регламент: доллар-квоты только парные), если тело без $."""
    if '$function$' in body:
        inner = body.split('$function$', 1)[1].rsplit('$function$', 1)[0]
        assert '$' not in inner, 'в теле %s есть $' % name
        body = body.replace('$function$', '$$')
    return body


co = norm_dq(psql("select pg_get_functiondef(p.oid) from pg_proc p "
          "join pg_namespace n on n.oid = p.pronamespace "
          "where n.nspname='public' and p.proname='create_order'").rstrip(), 'create_order')
anchor = "    v_comment := nullif(btrim(coalesce(p->>'comment', '')), '');"
assert co.count(anchor) == 1, 'якорь v_comment не найден/не единственен'
limits = anchor + """

    /* v8 (волна v0.17.0, внешний ревью 06.10.2026 — находка C3): лимит длины
       свободных текстовых полей — 1000 символов (решение владельца
       06.10.2026); телефон и e-mail ограничены масками валидации, позиции —
       лимитом 50 штук выше по телу функции */
    if length(v_name) > 1000 then
        raise exception 'Слишком длинное имя (не более 1000 символов)';
    end if;
    if length(v_address) > 1000 then
        raise exception 'Слишком длинный адрес (не более 1000 символов)';
    end if;
    if length(v_comment) > 1000 then
        raise exception 'Слишком длинный комментарий (не более 1000 символов)';
    end if;"""
co8 = co.replace(anchor, limits)
assert co8 != co and co8.count('не более 1000 символов') == 3

# ---- check_promo v2 --------------------------------------------------------
cp = norm_dq(psql("select pg_get_functiondef(p.oid) from pg_proc p "
          "join pg_namespace n on n.oid = p.pronamespace "
          "where n.nspname='public' and p.proname='check_promo'").rstrip(), 'check_promo')
assert cp.count('current_date') == 2, cp.count('current_date')
cp2 = cp.replace('current_date', "(now() at time zone 'Europe/Moscow')::date")
assert 'current_date' not in cp2 and cp2.count('Europe/Moscow') == 2

script26 = """-- ============================================================================
--  SISKU (черновик) — СКРИПТ 26: лимиты текстовых полей заказа + часовые пояса
-- ============================================================================
--  Волна v0.17.0 (07.10.2026) — обработка внешнего ревью 06.10.2026:
--  (а) находка C3: create_order v8 — лимит длины свободных текстовых полей
--      (customer_name / customer_address / comment) — 1000 символов
--      (решение владельца 06.10.2026: «лимит текстовых полей для создания
--      в заказе — 1000 символов»); читаемые ошибки (P0001 → friendlyDbError);
--  (б) находка C1: check_promo v2 — границы ДАТ действия промокода
--      (valid_from/valid_until) трактуются в локальном времени магазина
--      Europe/Moscow вместо UTC current_date (решение владельца 06.10.2026:
--      «должно быть [везде] локальное время»). Относительные окна (анти-спам
--      3 заказа / 10 минут в create_order, окна промокодов) — интервалы,
--      от часового пояса не зависят, не меняются. РЕГЛАМЕНТ ВРЕМЕНИ:
--      моменты — timestamptz/UTC; календарные границы — Europe/Moscow;
--      фронтенд — локальная дата устройства (dayKey(), грабля №1);
--      порт в боевой MySQL 8 — CONVERT_TZ (migration-plan §5.1 п. 18).
--  Идемпотентен: create or replace function. Порядок: после baseline 01–09.
--  Применим и к живой базе (инкремент — модель F21).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. create_order v8 (база — v7, скрипт 19: защита подтверждённого имени)
-- ----------------------------------------------------------------------------
%s;

comment on function public.create_order(jsonb) is %s;

-- ----------------------------------------------------------------------------
-- 2. check_promo v2 (границы дат — Europe/Moscow)
-- ----------------------------------------------------------------------------
%s;

comment on function public.check_promo(text, numeric) is %s;

-- ----------------------------------------------------------------------------
-- 3. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select (length(pg_get_functiondef(p.oid))
             - length(replace(pg_get_functiondef(p.oid),
                              'не более 1000 символов', '')))
            / length('не более 1000 символов')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'create_order')   as limit_msgs,        -- ждём 3
    (select pg_get_functiondef(p.oid) like '%%length(v_comment) > 1000%%'
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'create_order')   as create_order_v8,   -- ждём t
    (select (length(p.prosrc) - length(replace(p.prosrc,
                        'Europe/Moscow', ''))) / length('Europe/Moscow')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'check_promo')    as tz_occurrences,    -- ждём 2
    (select p.prosrc not like '%%current_date%%'
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'check_promo')    as utc_date_gone,     -- ждём t
    (select prosrc like '%%name_confirmed%%' from pg_proc
      where proname = 'create_order')                              as v7_base_kept;      -- ждём t (логика v7 не потеряна)
""" % (co8,
       q('v8 (волна v0.17.0, внешний ревью 06.10.2026 — C3): лимит длины текстовых полей заказа ≤1000 символов; база — v7 (волна v0.15.0, скрипт 19): подтверждённое имя не перезаписывается'),
       cp2,
       q('v2 (волна v0.17.0, внешний ревью 06.10.2026 — C1): границы дат действия промокода — в локальном времени магазина Europe/Moscow (решение владельца 06.10.2026)'))

# ---- 27: webp-пути ---------------------------------------------------------
pairs = ["('assets/img/hero-dark.jpg', 'assets/img/hero-dark.webp')",
         "('assets/img/hero.jpg', 'assets/img/hero.webp')"]
pairs += ["('assets/img/products/p%03d.jpg', 'assets/img/products/p%03d.webp')" % (i, i)
          for i in range(1, 9)]
pairs_sql = ',\n        '.join(pairs)

script27 = """-- ============================================================================
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
 where image_url like 'assets/img/products/%%.jpg';

-- ----------------------------------------------------------------------------
-- 2. site_content: известные пути изображений в значениях ключей
-- ----------------------------------------------------------------------------
do $$
declare
    m text[];
begin
    foreach m slice 1 in array array[
        %s
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
      where image_url like 'assets/img/products/%%.webp')             as products_webp,      -- ждём 8 (свежий стенд; живая база — фактическое число демо-товаров)
    (select count(*) from public.products
      where image_url like '%%.jpg')                                   as products_jpg_left,  -- ждём 0
    (select count(*) from public.site_content
      where value like '%%assets/img/%%.jpg%%')                         as content_jpg_left;   -- ждём 0
""" % pairs_sql

for name, body in [('26_field_limits_and_promo_timezone.sql', script26),
                   ('27_webp_image_paths.sql', script27)]:
    path = os.path.join(OUT, name)
    open(path, 'w', encoding='utf-8').write(body)
    print('записан', path, len(body), 'симв.')
