#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SISKU · tests/check-repo.py — автоматическая проверка целостности черновика.
v2 (v0.14.0, по независимому ревью F14/F20): все 17 страниц вместо 7,
все пары JS↔страница вместо 5, CSV через модуль csv (закавыченные запятые),
реестр supabase/README.md как источник REQUIRED (двусторонняя сверка),
контроль упоминания последнего SQL-скрипта в документации, эвристика
префлайта (скрипт с create policy обязан содержать to_regclass).
v2.1 (v0.14.1): в REQUIRED добавлены docs/plan/ (migration-plan, otchet,
voprosy-vladeltsu — плановые документы теперь в репозитории, F37),
docs/review-v0140.md и docs/update-v0141.md.
v2.2 (волна v0.15.0 — АН-12; подготовлен 05.10.2026): пути REQUIRED и
проверок приведены к структуре docs/ с подпапками plan/ priemka/ review/
setup/ update/ (перестройка 04.10.2026); в REQUIRED добавлены
docs/tz-proekta.md, docs/priemka/priemka-v014.md,
docs/review/SISKU-REVIEW-v0140.md, docs/plan/matrica-dostupa.md и бэкапы
контента data/site_content_rows.csv, data/brand_colors_rows.csv; проверка
CSV расширена на все data/*.csv; docs/review/SISKU-REVIEW-v0.13.1.md не
требуется — дубль удалён решением 05.10.2026 (основная репозиторная копия
отчёта v0.13.1 — docs/review/review-v0131.md, ревизия 4).
Состав волны v0.15.0 в REQUIRED: скрипты supabase/17–21 и
docs/update/update-v0150.md.
v2.3 (06.10.2026, вне волн — замена data/): бэкап содержимого базы переведён
на автовыгрузки Supabase — в REQUIRED 13 файлов data/*_rows.csv вместо
мастер-источников brands/categories/products/variants.csv (удалены из
репозитория 06.10.2026; посев каталога для новой базы — скрипт 05 или импорт
бэкапов, docs/setup/setup-supabase.md шаг 3); чтение CSV — utf-8-sig
(устойчивость к BOM автовыгрузок); CRLF автовыгрузок обрабатывается
csv-модулем (newline='') — проверка ровного числа колонок не менялась.
v2.4 (волна v0.16.0): в REQUIRED добавлены скрипты supabase/22–25,
docs/update/update-v0160.md, docs/priemka/priemka-v015.md и
docs/viki-reestr.md (опубликованная редакция реестра документации —
решение аналитика 06.10.2026); проверка последнего SQL-скрипта — 25.
v2.5 (волна v0.17.0): консолидация SQL — REQUIRED приведён к baseline
(01–05, 09) + инкременты 26–27 + исторический архив
supabase/archive/sql-01-25-v0160.md; удалённые скрипты 06–08, 10–25 больше
не требуются; изображения — WebP (hero.webp, products/*.webp); добавлены
docs/review/review-v0160.md и docs/update/update-v0170.md; НОВЫЕ ПРОВЕРКИ
(внешний ревью 06.10.2026, находки A1/E3): <iframe> только с sandbox,
srcdoc в JS только при sandbox на странице, запрет инлайновых on*-обработчиков
в HTML и в JS-строках (vendor не сканируется); проверка последнего
SQL-скрипта — 27.
v2.6 (волна v0.17.1): в REQUIRED добавлены docs/priemka/chek-list-priemki-
funkcionala.md и docs/update/update-v0171.md (решение Д2а аналитика от
08.10.2026); НОВЫЕ ПРОВЕРКИ (решения Д2б/Д2в): версии документов в перечне
структуры README = версии в шапках документов (таблица пар «файл → регэксп
шапки → маркер перечня», версии берутся из шапок живьём), README↔update-vXXX —
последняя инструкция волны упомянута в README (АН-26).
v2.9 (волна v0.20.0): в REQUIRED добавлены supabase/31_inventory_schema.sql,
supabase/32_inventory_rpc.sql, assets/js/inventory.js (панель
«Инвентаризация» — отдельный модуль, решение Д14 от 10.10.2026) и
docs/update/update-v0200.md; новая пара JS↔страница inventory.js↔
products.html; проверка последнего SQL-скрипта — 32; бэкап
data/writeoff_reasons_rows.csv создаётся волной, но в REQUIRED не входит
(Д13 — живой источник справочника база; CSV-проверка п.5 его сканирует).
v3.0 (волна v0.21.0): в REQUIRED добавлены supabase/33_badges.sql и
docs/update/update-v0210.md (бейджи карточки товара, fp №16); проверка
последнего SQL-скрипта — 33; бэкап data/badges_rows.csv создаётся волной,
но в REQUIRED не входит (Д9/паттерн Д13 — живой источник справочника база;
CSV-проверка п.5 его сканирует); новых пар JS↔страница нет (бейджи —
в существующих модулях site.js/products.js/manage.js).
v3.1 (волна v0.21.1 — ревизия документации и консолидация SQL 2, 17.10.2026):
REQUIRED приведён к консолидированному baseline ревизии 2 — записи
инкрементов 26–33 исключены (файлы заморожены в архиве
supabase/archive/sql-26-33-v0210.md — добавлен в REQUIRED), добавлен
docs/update/update-v0211.md; SECURITY.md/LICENSE.md ИСКЛЮЧЕНЫ из сверки
версии в шапке (решение аналитика 17.10.2026: вместо версионной шапки —
отметка «Версия: смотреть в README.md», документы волнами не обновляются);
проверка «последний SQL-скрипт» перестроена под модель консолидации 2:
инкрементов на диске нет — сверяется число «Следующий инкрементный скрипт — N»
из реестра supabase/README.md с упоминанием в техпаспорте и корневом README
(setup-supabase исключён — решение 17.10.2026: изменчивые данные живут
только в supabase/README.md); итоговый вывод — состав baseline и следующий
номер скрипта.
v3.2 (волна v0.22.0): в REQUIRED добавлены supabase/34_category_attrs.sql
(атрибуты по категориям, fp №14), supabase/35_client_segment_flags.sql
(кросс-сегменты клиентов, записка 6/Д4) и docs/update/update-v0220.md;
бэкапы data/category_attrs_rows.csv и data/product_attrs_rows.csv создаются
волной, но в REQUIRED не входят (паттерн Д13); новых пар JS↔страница нет
(атрибуты — в существующих модулях categories.js/products.js/site.js);
проверка последнего SQL-скрипта — 35 (инкременты снова на диске); в REQUIRED добавлен отчёт внутреннего ревью `docs/review/code-review-v0220.md` (задание аналитика 18.10.2026; шаблон — code-review-v040.md).
v3.3 (волна v0.22.1): в REQUIRED добавлены supabase/36_admin_page_bundles.sql
(бандлы чтения пяти админ-страниц — грабля №6, находка 4 ревью v0.22.0) и
docs/update/update-v0221.md; НОВАЯ ПРОВЕРКА 6.12 (Д4, находка 9 ревью
v0.22.0): число строк ACCESS_MATRIX (assets/js/users.js) = число строк
данных таблиц раздела «Матрица доступа» (docs/plan/matrica-dostupa.md) —
рассинхрон константы и документа ловится автоматически (сейчас 26 = 26);
последний скрипт — 36; новых пар JS↔страница нет (бандлы — в существующих
модулях products.js/manage.js/looks.js/categories.js/brandbook.js).

Запуск из корня репозитория:  python3 tests/check-repo.py
Проверяет (без сети и без базы):
  1. наличие обязательных файлов + двусторонняя сверка реестра supabase/README.md;
  2. локальные src/href во ВСЕХ HTML существуют на диске;
  3. url() в CSS существуют на диске;
  4. id, к которых обращается JS через $('…'), существуют в своей странице
     (все модули, кроме создаваемых динамически);
  5. CSV: ровное число колонок в каждой строке (парсер csv, кавычки учитываются);
  6. согласованность версии: SITE_VERSION в config.js = шапки README/SECURITY/LICENSE;
  6.5. регламент SQL: policyname, парные доллар-квоты, префлайт to_regclass
       в каждом скрипте с create policy (правило 6, фикс F20);
  6.6. последний SQL-скрипт упомянут в tehpasport/setup-supabase/README;
  6.7. util.js подключён на всех страницах (фикс F32);
  6.8. <iframe> только с sandbox; srcdoc в JS только при sandbox на странице (v2.5);
  6.9. запрет инлайновых on*-обработчиков в HTML и JS-строках (v2.5);
  6.10. версии документов в перечне структуры README = версии в шапках (v2.6, Д2б);
  6.11. последняя инструкция update-vXXX упомянута в README (v2.6, Д2в/АН-26);
  6.12. ACCESS_MATRIX (users.js) ↔ matrica-dostupa.md — число строк (v3.3, Д4);
  7. SQL: синтаксис (если установлен pglast; иначе проверка пропускается);
  8. HTML: сбалансированность тегов (все страницы).

Код выхода 0 — всё хорошо, 1 — есть замечания (список печатается).
"""
import csv
import io
import os
import re
import sys
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

problems = []
notes = []

# ---------- состав проекта ----------
HTML_PAGES = sorted(f for f in os.listdir('.') if f.endswith('.html'))

JS_PAGE = [
    ('assets/js/site.js', 'index.html'),
    ('assets/js/admin.js', 'admin.html'),
    ('assets/js/assembly.js', 'assembly.html'),
    ('assets/js/users.js', 'users.html'),
    ('assets/js/clients.js', 'clients.html'),
    ('assets/js/shop.js', 'shop.html'),
    ('assets/js/categories.js', 'categories.html'),
    ('assets/js/brands.js', 'brands.html'),
    ('assets/js/products.js', 'products.html'),
    ('assets/js/inventory.js', 'products.html'),   # v2.9 (Д14): панель «Инвентаризация» — отдельный модуль страницы товаров
    ('assets/js/looks.js', 'looks.html'),
    ('assets/js/manage.js', 'manage.html'),
    ('assets/js/sitecontent.js', 'sitecontent.html'),
    ('assets/js/brandbook.js', 'brandbook.html'),
    ('assets/js/admintheme.js', 'admin.html'),
    ('assets/js/mockauth.js', 'admin.html'),
    ('assets/js/util.js', 'index.html'),
    ('assets/js/brandvars.js', 'index.html'),
    ('assets/js/ui.js', 'index.html'),
    ('assets/js/config.js', 'index.html'),
]

REQUIRED = [
    'index.html', 'admin.html', 'login.html', 'assembly.html', 'users.html',
    'README.md', 'LICENSE.md', 'SECURITY.md',
    'assets/css/styles.css', 'assets/css/admin.css', 'assets/css/ui.css', 'assets/css/fonts.css',
    'assets/js/config.js', 'assets/js/ui.js', 'assets/js/util.js', 'assets/js/site.js', 'assets/js/admin.js',
    'assets/js/mockauth.js', 'assets/js/admintheme.js', 'assets/js/assembly.js', 'assets/js/users.js',
    'assets/vendor/supabase.min.js', 'assets/vendor/chart.umd.min.js',
    'assets/fonts/prata-cyrillic-400.woff2', 'assets/fonts/prata-latin-400.woff2',
    'assets/fonts/manrope-cyrillic-var.woff2', 'assets/fonts/manrope-latin-var.woff2',
    'assets/img/hero.webp',
    # data/ — бэкап содержимого БД: с 06.10.2026 автовыгрузки Supabase (*_rows.csv);
    # мастер-источники brands/categories/products/variants.csv удалены из репозитория
    # (посев каталога новой базы — скрипт 05 или импорт бэкапов, setup-supabase шаг 3)
    'data/brands_rows.csv', 'data/categories_rows.csv', 'data/products_rows.csv',
    'data/product_variants_rows.csv', 'data/order_statuses_rows.csv',
    'data/status_transitions_rows.csv', 'data/payment_methods_rows.csv',
    'data/delivery_methods_rows.csv', 'data/looks_rows.csv', 'data/look_items_rows.csv',
    'data/brand_templates_rows.csv',
    'supabase/01_schema.sql', 'supabase/02_rls_and_access.sql', 'supabase/03_functions.sql',
    'supabase/04_seed_references_and_content.sql', 'supabase/05_seed_catalog.sql',
    'supabase/09_admin_bundles.sql',
    'assets/img/hero-dark.webp', 'docs/update/update-v050.md', 'docs/update/update-v060.md',
    'shop.html', 'assets/js/shop.js', 'docs/update/update-v070.md',
    'products.html', 'assets/js/products.js', 'docs/update/update-v080.md',
    'categories.html', 'brands.html', 'manage.html', 'sitecontent.html', 'sitemap.html',
    'assets/js/categories.js', 'assets/js/brands.js', 'assets/js/manage.js', 'assets/js/sitecontent.js',
    'docs/update/update-v090.md', 'docs/update/update-v091.md',
    'looks.html', 'assets/js/looks.js', 'docs/update/update-v100.md',
    'brandbook.html', 'clients.html', 'assets/js/brandbook.js', 'assets/js/clients.js',
    'assets/js/brandvars.js', 'docs/update/update-v110.md',
    'supabase/README.md', 'docs/update/update-v111.md',
    'privacy.html', 'offer.html', 'docs/update/update-v0120.md',
    'docs/update/update-v0130.md', 'docs/update/update-v0131.md',
    'docs/setup/setup-repo-pages.md', 'docs/setup/setup-supabase.md', 'docs/update/update-v040.md',
    'docs/feature-proposals.md', 'docs/review/code-review-v040.md',
    'docs/tehpasport.md', 'tests/check-repo.py',
    # v0.14.0 — волна по независимому ревью (docs/review-v0131.md — отчёт ревьюера)
    'docs/update/update-v0140.md', 'docs/review/review-v0131.md',
    # v0.14.1 — патч по ревью волны v0.14.0 (docs/review-v0140.md); плановые
    # документы в репозитории (docs/plan/ — пункт ревью F37 закрыт)
    'docs/update/update-v0141.md', 'docs/review/review-v0140.md',
    'docs/plan/migration-plan.md', 'docs/plan/otchet.md', 'docs/plan/voprosy-vladeltsu.md',
    # v2.2 (05.10.2026): структура docs/ с подпапками; новые документы и бэкапы
    'docs/tz-proekta.md', 'docs/priemka/priemka-v014.md',
    'docs/review/SISKU-REVIEW-v0140.md', 'docs/plan/matrica-dostupa.md',
    'data/site_content_rows.csv', 'data/brand_colors_rows.csv',
    # v0.15.0 — волна по запискам приёмки v0.14.x (скрипты 17–21)
    'docs/update/update-v0150.md',
    # v2.4 (волна v0.16.0): возвраты + карантин (скрипты 22–25), инструкция
    # волны, обработка приёмки v0.15.0 и опубликованная редакция реестра
    # документации (docs/viki-reestr.md — решение аналитика 06.10.2026)
    'docs/update/update-v0160.md', 'docs/priemka/priemka-v015.md',
    'docs/viki-reestr.md',
    # v2.5 (волна v0.17.0): обработка внешнего ревью, инструкция волны и
    # исторический архив скриптов 01–25 (заморожен); записи инкрементов 26–27
    # исключены в v3.1 (консолидация ревизии 2 — файлы в архиве
    # supabase/archive/sql-26-33-v0210.md)
    'supabase/archive/sql-01-25-v0160.md',
    'docs/review/review-v0160.md', 'docs/update/update-v0170.md',
    # v2.6 (волна v0.17.1): универсальный чек-лист приёмки (регистрация — решение Д2а)
    # и инструкция волны
    'docs/priemka/chek-list-priemki-funkcionala.md', 'docs/update/update-v0171.md',
    # v2.7 (волна v0.18.0): карточка клиента — инструкция волны (записи
    # скриптов 28–29 исключены в v3.1 — архив sql-26-33-v0210.md)
    'docs/update/update-v0180.md',
    # v2.8 (волна v0.19.0): сегменты клиентов — инструкция волны (запись
    # скрипта 30 исключена в v3.1 — архив sql-26-33-v0210.md)
    'docs/update/update-v0190.md',
    # v2.9 (волна v0.20.0): инвентаризация и списания (модуль панели
    # inventory.js — пара с products.html, решение Д14) и инструкция волны;
    # бэкап data/writeoff_reasons_rows.csv в REQUIRED не входит (Д13);
    # записи скриптов 31–32 исключены в v3.1 — архив sql-26-33-v0210.md
    'assets/js/inventory.js', 'docs/update/update-v0200.md',
    # v3.0 (волна v0.21.0): бейджи карточки товара (fp №16) и инструкция
    # волны; бэкап data/badges_rows.csv в REQUIRED не входит (Д9 — паттерн
    # Д13); запись скрипта 33 исключена в v3.1 — архив sql-26-33-v0210.md
    'docs/update/update-v0210.md',
    # v3.1 (волна v0.21.1): консолидация ревизии 2 — архив инкрементов 26–33
    # и инструкция ревизии документации
    'supabase/archive/sql-26-33-v0210.md', 'docs/update/update-v0211.md',
    # v3.2 (волна v0.22.0): атрибуты по категориям (fp №14 — скрипт 34) и
    # кросс-сегменты клиентов (записка 6/Д4 — скрипт 35) + инструкция волны;
    # бэкапы data/category_attrs_rows.csv и data/product_attrs_rows.csv
    # создаются волной, но в REQUIRED не входят (паттерн Д13 — живой источник
    # справочника/значений база; CSV-проверка п.5 их сканирует)
    'supabase/34_category_attrs.sql', 'supabase/35_client_segment_flags.sql',
    'docs/update/update-v0220.md',
    # внутреннее ревью рабочей копии волны v0.22.0 (задание аналитика
    # 18.10.2026; шаблон — code-review-v040.md)
    'docs/review/code-review-v0220.md',
    # v3.3 (волна v0.22.1): бандлы чтения пяти админ-страниц (скрипт 36 —
    # грабля №6, находка 4 ревью v0.22.0) и инструкция волны; новых пар
    # JS↔страница нет (бандлы — в существующих модулях)
    'supabase/36_admin_page_bundles.sql', 'docs/update/update-v0221.md',
] + ['assets/img/products/p00%d.webp' % i for i in range(1, 9)]

# ---------- 1. обязательные файлы + реестр supabase/README.md ----------
for f in REQUIRED:
    if not os.path.isfile(f):
        problems.append('отсутствует файл: %s' % f)

# реестр скриптов в supabase/README.md — источник истины (частичная автогенерация REQUIRED):
# (а) каждый перечисленный в таблице файл существует;
# (б) каждый *.sql в папке перечислен в таблице.
readme_sql = io.open('supabase/README.md', encoding='utf-8').read()
listed = set(re.findall(r'`(\d\d_[\w.]+\.sql)`', readme_sql))
on_disk = set(f for f in os.listdir('supabase') if f.endswith('.sql'))
for f in sorted(listed):
    if not os.path.isfile('supabase/' + f):
        problems.append('supabase/README.md: в реестре числится %s, файла нет' % f)
for f in sorted(on_disk - listed):
    problems.append('supabase/README.md: скрипт %s отсутствует в реестре' % f)

BASELINE_NAMES = {'01_schema.sql', '02_rls_and_access.sql', '03_functions.sql',
                  '04_seed_references_and_content.sql', '05_seed_catalog.sql',
                  '09_admin_bundles.sql'}
increments = sorted(f for f in on_disk if f not in BASELINE_NAMES)
LAST_SQL = increments[-1] if increments else None
LAST_SQL_NN = LAST_SQL[:2] if LAST_SQL else None
# v3.1 (консолидация ревизии 2): инкрементов на диске может не быть —
# следующий номер берётся из реестра supabase/README.md
m_next = re.search(r'Следующий инкрементный скрипт — \*{0,2}(\d+)', readme_sql)
NEXT_SQL_NN = m_next.group(1) if m_next else None
if not m_next:
    problems.append('supabase/README.md: не найден маркер «Следующий инкрементный скрипт — N» (v3.1)')

# ---------- 2. ссылки во всех HTML ----------
for f in HTML_PAGES:
    html = io.open(f, encoding='utf-8').read()
    for m in re.findall(r'(?:^|[\s"\'(])(?:src|href)="([^"]+)"', html):
        if m.startswith(('http', 'tel:', 'mailto:', 'data:', '#')):
            continue
        if '.' not in m and '/' not in m:      # data-content-href="ключ" и т.п.
            continue
        path = m.split('#')[0].split('?')[0]
        if path and not os.path.isfile(path):
            problems.append('%s: битая ссылка %s' % (f, m))

# ---------- 3. url() в CSS ----------
for f in ['assets/css/fonts.css', 'assets/css/styles.css', 'assets/css/admin.css', 'assets/css/ui.css']:
    css = io.open(f, encoding='utf-8').read()
    for m in re.findall(r"url\('([^')]+)'\)", css):
        if m.startswith('data:'):
            continue
        p = os.path.normpath(os.path.join(os.path.dirname(f), m))
        if not os.path.isfile(p):
            problems.append('%s: битый url() %s' % (f, m))

# ---------- 4. id из JS существуют в своих страницах ----------
for js, page in JS_PAGE:
    if not os.path.isfile(js) or not os.path.isfile(page):
        continue
    src = io.open(js, encoding='utf-8').read()
    used = set(re.findall(r"\$\('([\w-]+)'\)", src))
    used |= set(re.findall(r"getElementById\('([\w-]+)'\)", src))
    have = set(re.findall(r'id="([^"]+)"', io.open(page, encoding='utf-8').read()))
    # id, создаваемые динамически (в innerHTML-строках любого модуля той же страницы)
    created = set()
    for other, p2 in JS_PAGE:
        if p2 == page and os.path.isfile(other):
            created |= set(re.findall(r'id=\\?"([\w-]+)', io.open(other, encoding='utf-8').read()))
    for i in sorted(used - have - created):
        if i.startswith(('oc-', 'lp', 'login-')):      # карточка заказа динамическая; login.html — инлайн
            continue
        problems.append('%s: id "%s" не найден в %s' % (js, i, page))

# ---------- 5. CSV (модуль csv — закавыченные запятые не ломают проверку) ----------
csv_files = sorted('data/' + n for n in os.listdir('data') if n.endswith('.csv'))
for f in csv_files:
    with io.open(f, encoding='utf-8-sig', newline='') as fh:  # v2.3: utf-8-sig — автовыгрузки могут приходить с BOM
        rows = list(csv.reader(fh))
    if not rows:
        problems.append('%s: пустой файл' % f)
        continue
    head = len(rows[0])
    for n, row in enumerate(rows):
        if not row:
            continue
        if len(row) != head:
            problems.append('%s: строка %d имеет другое число колонок (%d != %d)' % (f, n, len(row), head))

# ---------- 6. согласованность версии ----------
ver_js = re.search(r"SITE_VERSION = '([\d.]+-draft)'", io.open('assets/js/config.js', encoding='utf-8').read())
ver = ver_js.group(1) if ver_js else None
if not ver:
    problems.append('config.js: не найден SITE_VERSION')
else:
    head = io.open('README.md', encoding='utf-8').read()[:600]
    if ver not in head:
        problems.append('README.md: версия в шапке не совпадает с SITE_VERSION (%s)' % ver)
    # v3.1 (решение аналитика 17.10.2026): SECURITY.md/LICENSE.md не несут
    # версионной шапки и волнами не обновляются — контролируется отметка
    for f in ['SECURITY.md', 'LICENSE.md']:
        head2 = io.open(f, encoding='utf-8').read()[:800]
        if 'смотреть в README.md' not in head2:
            problems.append('%s: нет отметки «Версия: смотреть в README.md» в шапке (v3.1)' % f)

# ---------- 6.5. регламент SQL ----------
for f in sorted(os.listdir('supabase')):
    if not f.endswith('.sql'):
        continue
    src = io.open(os.path.join('supabase', f), encoding='utf-8').read()
    if re.search(r'\bpolicy_name\b', src):
        problems.append('supabase/%s: использовать pg_policies.policyname, а не policy_name' % f)
    for n, line in enumerate(src.split('\n'), 1):
        if re.search(r'(?<!\$)\$(?!\$)', line.split('--')[0]):
            problems.append('supabase/%s: одиночный $ в строке %d (доллар-квоты только парные)' % (f, n))
    # фикс F20 (v0.14.0): префлайт обязателен в каждом скрипте с политиками.
    # v3.1: DDL ищем вне доллар-квот и комментариев — упоминания «create policy»
    # внутри тел функций/комментариев политикой не являются (ложные срабатывания
    # на консолидированном baseline ревизии 2)
    _ddl = re.sub(r'\$\$.*?\$\$', '', src, flags=re.S)
    _ddl = re.sub(r'--[^\n]*', '', _ddl)
    if re.search(r'create policy\b', _ddl, re.I) and 'to_regclass' not in src:
        problems.append('supabase/%s: скрипт создаёт политики, но без префлайта to_regclass (правило 6)' % f)

# ---------- 6.6. реестр скриптов: последний/следующий номер в документации (v3.1) ----------
if LAST_SQL:
    # на диске есть инкременты — прежняя логика (без setup-supabase: изменчивые
    # данные скриптов живут только в supabase/README.md — решение 17.10.2026)
    doc_pats = ['%s_' % LAST_SQL_NN, '01…%s' % LAST_SQL_NN, '01–%s' % LAST_SQL_NN, '01-%s' % LAST_SQL_NN]
    for f in ['docs/tehpasport.md', 'README.md']:
        src = io.open(f, encoding='utf-8').read()
        if not any(p in src for p in doc_pats):
            problems.append('%s: не упомянут последний SQL-скрипт (%s) — документация устарела' % (f, LAST_SQL))
elif NEXT_SQL_NN:
    # baseline-only: следующий номер из реестра supabase/README.md должен быть
    # синхронизирован с техпаспортом и корневым README
    for f in ['docs/tehpasport.md', 'README.md']:
        src = io.open(f, encoding='utf-8').read()
        if NEXT_SQL_NN not in src:
            problems.append('%s: не упомянут следующий номер скрипта (%s) из реестра supabase/README.md — документация устарела' % (f, NEXT_SQL_NN))

# ---------- 6.7. util.js подключён на всех страницах ----------
for f in HTML_PAGES:
    if 'assets/js/util.js' not in io.open(f, encoding='utf-8').read():
        problems.append('%s: не подключён assets/js/util.js (общие утилиты, фикс F32)' % f)

# ---------- 6.8. iframe/srcdoc — только с sandbox (v2.5, ревью A1/E3) ----------
for f in HTML_PAGES:
    html = io.open(f, encoding='utf-8').read()
    for m in re.finditer(r'<iframe\b[^>]*>', html):
        if 'sandbox' not in m.group(0):
            problems.append('%s: <iframe> без атрибута sandbox (ревью A1 — скрипты в предпросмотре недопустимы)' % f)
for js, page in JS_PAGE:
    if not os.path.isfile(js):
        continue
    srcjs = io.open(js, encoding='utf-8').read()
    if '.srcdoc' in srcjs:
        phtml = io.open(page, encoding='utf-8').read() if os.path.isfile(page) else ''
        if 'sandbox' not in phtml:
            problems.append('%s: присваивается srcdoc, но на странице %s нет sandbox у iframe (ревью A1)' % (js, page))

# ---------- 6.9. запрет инлайновых on*-обработчиков (v2.5, ревью E3) ----------
INLINE_ON = re.compile(r'\bon(?:error|load|click|change|input|submit|focus|blur|mouseover|mouseout)\s*=\s*(?:\\?["\'])')
for f in HTML_PAGES:
    html = io.open(f, encoding='utf-8').read()
    m = INLINE_ON.search(html)
    if m:
        problems.append('%s: инлайновый on*-обработчик «%s» (запрещено с v2.5 — делегирование, см. util.js)' % (f, m.group(0)[:30]))
for f in sorted(os.listdir('assets/js')):
    if not f.endswith('.js'):
        continue
    srcjs = io.open(os.path.join('assets/js', f), encoding='utf-8').read()
    m = INLINE_ON.search(srcjs)
    if m:
        problems.append('assets/js/%s: инлайновый on*-обработчик в строке разметки «%s» (запрещено с v2.5)' % (f, m.group(0)[:30]))

# ---------- 6.10. версии документов: перечень README = шапка (v2.6, Д2б) ----------
# Таблица пар: файл → регэксп версии в шапке → маркер упоминания в перечне README.
# Версии НЕ захардкожены: берутся из шапок живьём и сравниваются с перечнем
# структуры README — при bump версии документа правка check-repo не нужна,
# рассинхрон «документ обновлён, перечень README — нет» ловится автоматически.
DOC_VERSIONS = [
    ('docs/plan/migration-plan.md',    r'Версия документа:\*\*\s*([\d.]+)', 'v{}'),
    ('docs/tz-proekta.md',             r'Версия документа:\*\*\s*([\d.]+)', 'v{}'),
    ('docs/plan/otchet.md',            r'Версия документа:\*\*\s*([\d.]+)', 'v{}'),
    ('docs/plan/matrica-dostupa.md',   r'Версия документа:\*\*\s*([\d.]+)', 'v{}'),
    ('docs/plan/voprosy-vladeltsu.md', r'ред\.\s*(\d+\.\d+)',               'ред. {}'),
]
readme_full = io.open('README.md', encoding='utf-8').read()
for path, rx, marker in DOC_VERSIONS:
    src = io.open(path, encoding='utf-8').read()
    m = re.search(rx, src)
    if not m:
        problems.append('%s: версия документа не найдена в шапке — регэксп таблицы DOC_VERSIONS устарел' % path)
        continue
    v = marker.format(m.group(1))
    fname = os.path.basename(path)
    if not any(fname in ln and v in ln for ln in readme_full.split('\n')):
        problems.append('README.md: «%s» не упомянут в перечне с версией %s (версия в шапке документа) — рассинхрон перечня' % (fname, v))

# ---------- 6.11. README ↔ update-vXXX: последняя инструкция упомянута (v2.6, Д2в/АН-26) ----------
upd_files = [f for f in os.listdir('docs/update') if re.fullmatch(r'update-v\d+\.md', f)]
if upd_files:
    latest_upd = max(upd_files, key=lambda f: int(re.search(r'\d+', f).group(0)))
    if latest_upd not in readme_full:
        problems.append('README.md: последняя инструкция обновления %s не упомянута (сверка README↔update-vXXX, v2.6)' % latest_upd)

# ---------- 6.12. ACCESS_MATRIX (users.js) ↔ matrica-dostupa.md (v3.3, Д4/находка 9 ревью v0.22.0) ----------
# Контроль по ЧИСЛУ СТРОК (предложение ревью): строки константы ACCESS_MATRIX
# в users.js vs строки данных таблиц документа matrica-dostupa.md (все строки,
# начинающиеся с «|», кроме заголовков «| Функционал» и разделителей «|---…» —
# в документе только таблицы матрицы; при появлении иных таблиц контроль
# потребует осознанной правки). Сверка текстов строк — кандидат боевого
# блока M2 (серверные ACL).
users_src = io.open('assets/js/users.js', encoding='utf-8').read()
m_mx = re.search(r'var ACCESS_MATRIX = \[(.*?)\n  \];', users_src, re.S)
if not m_mx:
    problems.append('users.js: ACCESS_MATRIX не найден — регэксп контроля 6.12 устарел (v3.3)')
else:
    mx_rows = len(re.findall(r"^\s+\['", m_mx.group(1), re.M))
    md_src = io.open('docs/plan/matrica-dostupa.md', encoding='utf-8').read()
    md_rows = sum(1 for ln in md_src.split('\n')
                  if ln.startswith('|') and not ln.startswith('| Функционал')
                  and not re.match(r'^\|[\s\-|]+\|$', ln.strip()))
    if mx_rows != md_rows:
        problems.append('Д4 (v3.3): ACCESS_MATRIX (users.js) — %d строк, '
                        'matrica-dostupa.md — %d строк данных: рассинхрон '
                        '(изменение матрицы — только решением владельца, пара: '
                        'документ + константа)' % (mx_rows, md_rows))
    else:
        notes.append('контроль Д4 (6.12): ACCESS_MATRIX = matrica-dostupa.md — %d строк' % mx_rows)

# ---------- 7. SQL (опционально) ----------
try:
    import pglast
    for f in sorted(os.listdir('supabase')):
        if f.endswith('.sql'):
            try:
                pglast.parse_sql(io.open(os.path.join('supabase', f), encoding='utf-8').read())
            except Exception as e:
                problems.append('supabase/%s: ошибка синтаксиса: %s' % (f, e))
except ImportError:
    notes.append('pglast не установлен — проверка синтаксиса SQL пропущена (pip install pglast)')

# ---------- 8. сбалансированность HTML (все страницы) ----------
VOID = {'meta', 'link', 'img', 'br', 'input', 'hr', 'source', 'path', 'rect', 'text', 'circle'}


class P(HTMLParser):
    def __init__(self):
        HTMLParser.__init__(self, convert_charrefs=True)
        self.stack, self.errs = [], []

    def handle_starttag(self, t, a):
        if t not in VOID:
            self.stack.append(t)

    def handle_endtag(self, t):
        if t in VOID:
            return
        if self.stack and self.stack[-1] == t:
            self.stack.pop()
        else:
            self.errs.append((t, self.getpos()))


for f in HTML_PAGES:
    p = P()
    p.feed(io.open(f, encoding='utf-8').read())
    if p.errs or p.stack:
        problems.append('%s: несбалансированные теги %s %s' % (f, p.errs[:3], p.stack[:3]))

# ---------- вывод ----------
for n in notes:
    print('— ' + n)
if problems:
    print('НАЙДЕНО ПРОБЛЕМ: %d' % len(problems))
    for p in problems:
        print('  ✗ ' + p)
    sys.exit(1)
if increments:
    print('✓ check-repo v3.3: все проверки пройдены (версия %s, страниц %d, SQL: baseline 6 + инкременты, последний %s)'
          % (ver, len(HTML_PAGES), LAST_SQL))
else:
    print('✓ check-repo v3.3: все проверки пройдены (версия %s, страниц %d, SQL: baseline ревизии 2 — 6 скриптов, следующий инкремент %s)'
          % (ver, len(HTML_PAGES), NEXT_SQL_NN))
sys.exit(0)
