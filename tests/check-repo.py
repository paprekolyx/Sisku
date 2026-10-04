#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SISKU · tests/check-repo.py — автоматическая проверка целостности черновика.
v2 (v0.14.0, по независимому ревью F14/F20): все 17 страниц вместо 7,
все пары JS↔страница вместо 5, CSV через модуль csv (закавыченные запятые),
реестр supabase/README.md как источник REQUIRED (двусторонняя сверка),
контроль упоминания последнего SQL-скрипта в документации, эвристика
префлайта (скрипт с create policy обязан содержать to_regclass).

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
    'assets/img/hero.jpg',
    'data/brands.csv', 'data/categories.csv', 'data/products.csv', 'data/variants.csv',
    'supabase/01_schema.sql', 'supabase/02_rls_and_access.sql', 'supabase/03_functions.sql',
    'supabase/04_seed_references_and_content.sql', 'supabase/05_seed_catalog.sql',
    'supabase/06_remove_paid_status.sql', 'supabase/07_draft_v040.sql', 'supabase/08_text_fixes.sql', 'supabase/09_admin_bundles.sql',
    'assets/img/hero-dark.jpg', 'docs/update-v050.md', 'docs/update-v060.md',
    'shop.html', 'assets/js/shop.js', 'supabase/10_promo_and_tracking.sql', 'docs/update-v070.md',
    'products.html', 'assets/js/products.js', 'supabase/11_product_management.sql', 'docs/update-v080.md',
    'categories.html', 'brands.html', 'manage.html', 'sitecontent.html', 'sitemap.html',
    'assets/js/categories.js', 'assets/js/brands.js', 'assets/js/manage.js', 'assets/js/sitecontent.js',
    'supabase/12_manage_policies.sql', 'docs/update-v090.md', 'docs/update-v091.md',
    'looks.html', 'assets/js/looks.js', 'supabase/13_reserve_and_looks.sql', 'docs/update-v100.md',
    'brandbook.html', 'clients.html', 'assets/js/brandbook.js', 'assets/js/clients.js',
    'assets/js/brandvars.js', 'supabase/14_brandbook.sql', 'docs/update-v110.md',
    'supabase/README.md', 'docs/update-v111.md',
    'privacy.html', 'offer.html', 'docs/update-v0120.md',
    'supabase/15_clients_and_promo_stats.sql', 'docs/update-v0130.md', 'docs/update-v0131.md',
    'docs/setup-repo-pages.md', 'docs/setup-supabase.md', 'docs/update-v040.md',
    'docs/feature-proposals.md', 'docs/code-review-v040.md',
    'docs/tehpasport.md', 'tests/check-repo.py',
    # v0.14.0 — волна по независимому ревью (docs/review-v0131.md — отчёт ревьюера)
    'supabase/16_race_and_integrity_fixes.sql', 'docs/update-v0140.md', 'docs/review-v0131.md',
] + ['assets/img/products/p00%d.jpg' % i for i in range(1, 9)]

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

LAST_SQL = max(on_disk) if on_disk else None
LAST_SQL_NN = LAST_SQL[:2] if LAST_SQL else '??'

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
for f in ['data/brands.csv', 'data/categories.csv', 'data/products.csv', 'data/variants.csv']:
    with io.open(f, encoding='utf-8', newline='') as fh:
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
    for f in ['README.md', 'SECURITY.md', 'LICENSE.md']:
        head = io.open(f, encoding='utf-8').read()[:600]
        if ver not in head:
            problems.append('%s: версия в шапке не совпадает с SITE_VERSION (%s)' % (f, ver))

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
    # фикс F20 (v0.14.0): префлайт обязателен в каждом скрипте с политиками
    if re.search(r'create policy\b', src, re.I) and 'to_regclass' not in src:
        problems.append('supabase/%s: скрипт создаёт политики, но без префлайта to_regclass (правило 6)' % f)

# ---------- 6.6. последний SQL-скрипт упомянут в документации ----------
if LAST_SQL:
    doc_pats = ['%s_' % LAST_SQL_NN, '01…%s' % LAST_SQL_NN, '01–%s' % LAST_SQL_NN, '01-%s' % LAST_SQL_NN]
    for f in ['docs/tehpasport.md', 'docs/setup-supabase.md', 'README.md']:
        src = io.open(f, encoding='utf-8').read()
        if not any(p in src for p in doc_pats):
            problems.append('%s: не упомянут последний SQL-скрипт (%s) — документация устарела' % (f, LAST_SQL))

# ---------- 6.7. util.js подключён на всех страницах ----------
for f in HTML_PAGES:
    if 'assets/js/util.js' not in io.open(f, encoding='utf-8').read():
        problems.append('%s: не подключён assets/js/util.js (общие утилиты, фикс F32)' % f)

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
print('✓ check-repo v2: все проверки пройдены (версия %s, страниц %d, SQL-скриптов %d, последний %s)'
      % (ver, len(HTML_PAGES), len(on_disk), LAST_SQL))
sys.exit(0)
