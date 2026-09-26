#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SISKU · tests/check-repo.py — автоматическая проверка целостности черновика.

Запуск из корня репозитория:  python3 tests/check-repo.py
Проверяет (без сети и без базы):
  1. наличие обязательных файлов;
  2. локальные src/href в HTML существуют на диске;
  3. url() в CSS существуют на диске;
  4. id, к которым обращается JS через $('…'), существуют в своей странице
     (кроме создаваемых динамически);
  5. CSV: ровное число колонок в каждой строке;
  6. согласованность версии: SITE_VERSION в config.js = шапки README/SECURITY/LICENSE;
  7. SQL: синтаксис (если установлен pglast; иначе проверка пропускается);
  8. HTML: сбалансированность тегов.

Код выхода 0 — всё хорошо, 1 — есть замечания (список печатается).
"""
import os
import re
import sys
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

problems = []
notes = []

REQUIRED = [
    'index.html', 'admin.html', 'login.html', 'assembly.html', 'users.html',
    'README.md', 'LICENSE.md', 'SECURITY.md',
    'assets/css/styles.css', 'assets/css/admin.css', 'assets/css/ui.css', 'assets/css/fonts.css',
    'assets/js/config.js', 'assets/js/ui.js', 'assets/js/site.js', 'assets/js/admin.js',
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
    'docs/setup-repo-pages.md', 'docs/setup-supabase.md', 'docs/update-v040.md',
    'docs/feature-proposals.md', 'docs/code-review-v040.md',
] + ['assets/img/products/p00%d.jpg' % i for i in range(1, 9)]

# ---------- 1. обязательные файлы ----------
for f in REQUIRED:
    if not os.path.isfile(f):
        problems.append('отсутствует файл: %s' % f)

# ---------- 2. ссылки в HTML ----------
PAGES = ['index.html', 'admin.html', 'login.html', 'assembly.html', 'users.html']
for f in PAGES:
    if not os.path.isfile(f):
        continue
    html = open(f, encoding='utf-8').read()
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
    css = open(f, encoding='utf-8').read()
    for m in re.findall(r"url\('([^')]+)'\)", css):
        if m.startswith('data:'):
            continue
        p = os.path.normpath(os.path.join(os.path.dirname(f), m))
        if not os.path.isfile(p):
            problems.append('%s: битый url() %s' % (f, m))

# ---------- 4. id из JS существуют в своих страницах ----------
JS_PAGE = [
    ('assets/js/site.js', 'index.html'),
    ('assets/js/admin.js', 'admin.html'),
    ('assets/js/assembly.js', 'assembly.html'),
    ('assets/js/users.js', 'users.html'),
]
for js, page in JS_PAGE:
    src = open(js, encoding='utf-8').read()
    used = set(re.findall(r"\$\('([\w-]+)'\)", src))
    have = set(re.findall(r'id="([^"]+)"', open(page, encoding='utf-8').read()))
    created = set(re.findall(r'id=\\?"([\w-]+)', src))          # создаются в innerHTML
    for i in sorted(used - have - created):
        if i.startswith('oc-'):                                  # карточка заказа целиком динамическая
            continue
        problems.append('%s: id "%s" не найден в %s' % (js, i, page))

# ---------- 5. CSV ----------
for f in ['data/brands.csv', 'data/categories.csv', 'data/products.csv', 'data/variants.csv']:
    lines = open(f, encoding='utf-8').read().strip().split('\n')
    head = len(lines[0].split(','))
    for n, line in enumerate(lines):
        if len(line.split(',')) != head:
            problems.append('%s: строка %d имеет другое число колонок' % (f, n))

# ---------- 6. согласованность версии ----------
ver_js = re.search(r"SITE_VERSION = '([\d.]+-draft)'", open('assets/js/config.js', encoding='utf-8').read())
ver = ver_js.group(1) if ver_js else None
if not ver:
    problems.append('config.js: не найден SITE_VERSION')
else:
    for f in ['README.md', 'SECURITY.md', 'LICENSE.md']:
        head = open(f, encoding='utf-8').read()[:600]
        if ver not in head:
            problems.append('%s: версия в шапке не совпадает с SITE_VERSION (%s)' % (f, ver))

# ---------- 7. SQL (опционально) ----------
try:
    import pglast
    for f in sorted(os.listdir('supabase')):
        if f.endswith('.sql'):
            try:
                pglast.parse_sql(open(os.path.join('supabase', f), encoding='utf-8').read())
            except Exception as e:
                problems.append('supabase/%s: ошибка синтаксиса: %s' % (f, e))
except ImportError:
    notes.append('pglast не установлен — проверка синтаксиса SQL пропущена (pip install pglast)')

# ---------- 8. сбалансированность HTML ----------
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


for f in PAGES:
    if not os.path.isfile(f):
        continue
    p = P()
    p.feed(open(f, encoding='utf-8').read())
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
print('✓ check-repo: все проверки пройдены (версия %s)' % ver)
sys.exit(0)
