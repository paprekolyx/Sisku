#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.22.0 — сборка свежей базы PostgreSQL 15 и верификация скриптов 34–35.

Паттерн run_v0210.py: свежая база sisku_v22, цепочка baseline ревизии 2
(01–05, 09) + инкременты 34 (атрибуты по категориям, fp №14) и 35
(кросс-сегменты клиентов, Д4); самопроверки сверяются с ожидаемыми строками
(34 — методика Д11: проектные функции по явному списку = 33; голое число —
справочно, на живой +rls_auto_enable); затем смоук S1–S14 (smoke_v0220.sql),
S15 — RLS под anon (category_attrs/product_attrs: публичное чтение,
insert/update/delete — запрет, запись только через RPC; RPC под anon
исполняются) и повторный прогон 34/35 (no-op: самопроверки идентичны,
счётчики не меняются).

Запуск из корня клона Sisku:
    python3 workaichat/pgtest/run_v0220.py
Нужен локальный PostgreSQL 15. Подключение — переменные окружения:
PGHOST (127.0.0.1), PGPORT (5433), PGUSER (postgres),
PSQLBIN (psql из PATH либо /usr/lib/postgresql/15/bin/psql).
Статика фронтенда (S16) — после правок JS/HTML; отключается SKIP_STATIC=1.
"""
import os
import shutil
import subprocess
import sys

SRC = 'supabase'
DB = 'sisku_v22'

PGHOST = os.environ.get('PGHOST', '127.0.0.1')
PGPORT = os.environ.get('PGPORT', '5433')
PGUSER = os.environ.get('PGUSER', 'postgres')
PSQL = os.environ.get('PSQLBIN') or (
    shutil.which('psql') or '/usr/lib/postgresql/15/bin/psql')

# ожидаемые строки самопроверок (psql -At); baseline — ревизия 2
# (supabase/README.md — единственный источник реестра)
CHAIN = [
    ('01_schema.sql',                      '30|30|t|57'),
    ('02_rls_and_access.sql',              '72|25|17|18|12|0'),
    ('03_functions.sql',                   '20|t|t|t'),
    ('04_seed_references_and_content.sql', '7|8|3|4|1|0|4|5|5|73|18|3|20|1'),
    ('05_seed_catalog.sql',                '6|6|8|20|0|t'),
    ('09_admin_bundles.sql',               '9|t|t|29'),
    ('34_category_attrs.sql',              '32|74|53|22|11|33|t'),
    ('35_client_segment_flags.sql',        't|t'),
]

fails = []


def psql_args(db):
    return [PSQL, '-h', PGHOST, '-p', PGPORT, '-U', PGUSER, '-d', db,
            '-v', 'ON_ERROR_STOP=1', '-q', '-At']


def pg(sql, db='postgres'):
    r = subprocess.run(psql_args(db) + ['-c', sql],
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def pg_file(path, db=DB):
    r = subprocess.run(psql_args(db) + ['-f', path],
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


# ---------------------------------------------------------------- подготовка
rc, out, err = pg('drop database if exists %s' % DB)
assert rc == 0, err
rc, out, err = pg('create database %s' % DB)
assert rc == 0, err

# роли Supabase (политики 02/34 ссылаются на anon/authenticated)
for role in ['anon', 'authenticated', 'service_role']:
    sql = ("do $$ begin execute 'create role " + role + " nologin'; "
           "exception when duplicate_object then null; end $$;")
    pg(sql)
pg('grant usage on schema public to anon, authenticated, service_role', db=DB)

# ---------------------------------------------------------------- цепочка
for fname, expect in CHAIN:
    rc, out, err = pg_file(os.path.join(SRC, fname))
    lines = [l for l in out.split('\n') if l.strip()]
    if rc != 0:
        fails.append('%s: psql rc=%d\n%s' % (fname, rc, err[:800]))
        continue
    if expect in lines:
        print('OK  %-42s самопроверка: %s' % (fname, expect))
    else:
        fails.append('%s: самопроверка — ожидали «%s», получили «%s»'
                     % (fname, expect, ' / '.join(lines[-3:])))

# ---------------------------------------------------------------- смоук S1–S14
rc, out, err = pg_file('workaichat/pgtest/smoke_v0220.sql')
if rc != 0:
    fails.append('smoke: psql rc=%d\n%s' % (rc, err[:800]))
else:
    passes = 0
    for line in out.split('\n'):
        if not line.strip():
            continue
        print('    ' + line)
        if line.startswith('FAIL'):
            fails.append('smoke: ' + line)
        elif line.startswith('PASS'):
            passes += 1
    print('    смоук S1–S14: PASS %d из 14' % passes)
    if passes != 14:
        fails.append('smoke: PASS %d из 14' % passes)

# ---------------------------------------------------------------- S15: RLS под anon
# эмуляция живого Supabase: anon имеет табличные гранты (default privileges),
# доступ ограничивают политики RLS
pg('grant select, insert, update, delete on all tables in schema public to anon', db=DB)
pg('grant usage, select on all sequences in schema public to anon', db=DB)
pg('grant execute on all functions in schema public to anon', db=DB)

rc, out, err = pg('set role anon; select count(*) from public.category_attrs', db=DB)
if rc == 0 and out == '53':
    print('OK  S15 RLS: anon читает category_attrs (53 строки, публичное чтение)')
else:
    fails.append('S15 RLS select category_attrs: rc=%d out=%s err=%s' % (rc, out, err[:200]))

rc, out, err = pg('set role anon; select count(*) from public.product_attrs', db=DB)
if rc == 0 and out.isdigit():
    print('OK  S15 RLS: anon читает product_attrs (%s строк)' % out)
else:
    fails.append('S15 RLS select product_attrs: rc=%d out=%s err=%s' % (rc, out, err[:200]))

probes_insert = [
    ("insert into public.category_attrs (category_id, code, name) "
     "values (1, 'anon_probe', 'Проба')", 'insert category_attrs'),
    ("insert into public.product_attrs (product_id, attr_id, value) "
     "values (1, 1, 'взлом')", 'insert product_attrs'),
]
denied = 0
for sql, name in probes_insert:
    rc, out, err = pg('set role anon; ' + sql, db=DB)
    if rc != 0 and 'row-level security' in err:
        denied += 1
    else:
        fails.append('S15 RLS %s: ожидали запрет RLS, получили rc=%d out=%s err=%s'
                     % (name, rc, out, err[:200]))

# update/delete без политик — не ошибка, а 0 затронутых строк (RLS скрывает
# строки): пробы «выполнить под anon + данные не изменились»
rc0, vals_before, _ = pg('select count(*) from public.product_attrs', db=DB)
probes_silent = [
    ("update public.category_attrs set name = 'взлом' where code = 'composition'",
     "select count(*) from public.category_attrs where name = 'взлом'", '0',
     'update category_attrs'),
    ("delete from public.category_attrs where code = 'composition'",
     "select count(*) from public.category_attrs where code = 'composition'", '4',
     'delete category_attrs'),
    ("delete from public.product_attrs",
     'select count(*) from public.product_attrs', vals_before,
     'delete product_attrs'),
]
silent = 0
for sql, check, expect, name in probes_silent:
    rc, out, err = pg('set role anon; ' + sql, db=DB)
    rc2, out2, err2 = pg(check, db=DB)
    if rc == 0 and out2 == expect:
        silent += 1
    else:
        fails.append('S15 RLS %s: ожидали 0 затронутых строк (контроль «%s»), '
                     'получили rc=%d/%d out=%s (ожидали %s) %s'
                     % (name, check, rc, rc2, out2, expect, err2[:200]))
if denied == len(probes_insert) and silent == len(probes_silent):
    print('OK  S15 RLS: запись под anon закрыта — insert: запрет RLS (%d/%d); '
          'update/delete: 0 затронутых строк (%d/%d) — только RPC '
          '(write-политик нет)' % (denied, len(probes_insert),
                                   silent, len(probes_silent)))

rc, out, err = pg("set role anon; select (draft_attrs_bundle() ? 'attrs') "
                  "and (draft_attrs_bundle() ? 'values')", db=DB)
if rc == 0 and out == 't':
    print('OK  S15 RPC: draft_attrs_bundle под anon исполняется (SECURITY DEFINER)')
else:
    fails.append('S15 RPC draft_attrs_bundle под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))

rc, out, err = pg("set role anon; select (draft_storefront_bundle() ? 'attr_dict') "
                  "and (draft_clients_bundle() ? 'thresholds')", db=DB)
if rc == 0 and out == 't':
    print('OK  S15 RPC: бандлы витрины v4 (attr_dict) и клиентов v4 (thresholds) под anon')
else:
    fails.append('S15 бандлы v4 под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))

rc, out, err = pg("set role anon; select draft_save_product_attrs("
                  "(select id from products order by id limit 1), '{}'::jsonb)->>'ok'", db=DB)
if rc == 0 and out == 'true':
    print('OK  S15 RPC: draft_save_product_attrs под anon исполняется (пустой набор — ok)')
else:
    fails.append('S15 RPC draft_save_product_attrs под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))

rc, out, err = pg("set role anon; select draft_save_product_badges(jsonb_build_object("
                  "'product_id', (select id from products order by id limit 1), "
                  "'badge_ids', jsonb_build_array((select id from badges where code = 'new'))"
                  "))->>'ok'", db=DB)
if rc == 0 and out == 'true':
    print('OK  S15 регресс: draft_save_product_badges под anon (v0.21.0)')
else:
    fails.append('S15 регресс draft_save_product_badges под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))

# ------------------------------------------- идемпотентность: повторный прогон 34/35
before = {}
for q, key in [("select count(*) from public.category_attrs", 'attrs'),
               ("select count(*) from public.product_attrs", 'values'),
               ("select count(*) from pg_policies where schemaname = 'public'", 'policies')]:
    rc, out, err = pg(q, db=DB)
    before[key] = out

rerun_ok = True
for fname, expect in [('34_category_attrs.sql', '32|74|53|22|11|33|t'),
                      ('35_client_segment_flags.sql', 't|t')]:
    rc, out, err = pg_file(os.path.join(SRC, fname))
    lines = [l for l in out.split('\n') if l.strip()]
    if rc != 0 or expect not in lines:
        rerun_ok = False
        fails.append('Повторный прогон %s: rc=%d, самопроверка «%s» (ожидали «%s») %s'
                     % (fname, rc, ' / '.join(lines[-3:]), expect, err[:300]))

after = {}
for q, key in [("select count(*) from public.category_attrs", 'attrs'),
               ("select count(*) from public.product_attrs", 'values'),
               ("select count(*) from pg_policies where schemaname = 'public'", 'policies')]:
    rc, out, err = pg(q, db=DB)
    after[key] = out

if rerun_ok and before == after:
    print('OK  Идемпотентность: повторный прогон 34/35 — самопроверки идентичны, '
          'счётчики не изменились (attrs %s, values %s, policies %s)'
          % (after['attrs'], after['values'], after['policies']))
else:
    fails.append('Идемпотентность: до=%s после=%s' % (before, after))

# ---------------------------------------------------------------- S16: статика фронтенда
if os.environ.get('SKIP_STATIC') != '1':
    def read(fp):
        with open(fp, encoding='utf-8') as f:
            return f.read()

    site_js = read('assets/js/site.js')
    prod_js = read('assets/js/products.js')
    cat_js = read('assets/js/categories.js')
    inv_js = read('assets/js/inventory.js')
    adm_js = read('assets/js/admin.js')
    users_js = read('assets/js/users.js')
    looks_js = read('assets/js/looks.js')
    clients_js = read('assets/js/clients.js')
    css = read('assets/css/styles.css')
    acss = read('assets/css/admin.css')
    idx = read('index.html')
    prod_html = read('products.html')
    adm_html = read('admin.html')
    users_html = read('users.html')
    manage_html = read('manage.html')
    bb_html = read('brandbook.html')

    checks = [
        ('site.js: attr_dict/фильтр/чипы (fp №14)', all(
            m in site_js for m in ['attr_dict', 'is_filterable', 'show_in_list',
                                   'renderAttrFilters', 'renderAttrChips',
                                   'renderProductAttrs', 'card-badges'])),
        ('site.js: бейджи — title + контейнер flex-wrap (П12в/Д8)',
         'title=' in site_js and '--bi' not in site_js),
        ('site.js: ссылки ПДн/оферты в согласии (П1)', all(
            m in site_js for m in ['linkifyConsent', 'privacy.html', 'offer.html',
                                   'consent-fallback'])),
        ('index.html: attr-filters + pm-attrs + consent-fallback', all(
            m in idx for m in ['id="attr-filters"', 'id="pm-attrs"',
                               'id="consent-fallback"'])),
        ('products.js: бандл атрибутов + RPC (fp №14)', all(
            m in prod_js for m in ['draft_attrs_bundle', 'draft_save_product_attrs',
                                   'renderAttrEditor', 'collectAttrValues'])),
        ('products.js: «Предпросмотр» из таблицы (П14/Д12) + base href (П13)', all(
            m in prod_js for m in ['data-preview', 'openDbPreview', '<base href='])),
        ('products.html: секция атрибутов + лист-модалка + сегмент знака (П16/П26)', all(
            m in prod_html for m in ['pf-attrs-field', 'inv-sheet-backdrop',
                                     'inv-w-sign', 'inv-sheet-csv'])),
        ('products.html: служебные пометки убраны из UI-текстов (П17)',
         '(решение Д2)' not in prod_html
         and '(решение владельца 10.10.2026' not in prod_html),
        ('products.html: «Журнал списаний и излишков» (П18)',
         'Журнал списаний и излишков' in prod_html),
        ('categories.js: конструктор атрибутов (RPC)', all(
            m in cat_js for m in ['admin_save_category_attr',
                                  'admin_delete_category_attr', 'openAttrs'])),
        ('inventory.js: CSV листа/итогов (П19/Д6) + знак операции (П26)', all(
            m in inv_js for m in ['sisku-invent-list', 'sisku-invent-itogi',
                                  'exportSheetCsv', 'syncWoSign', 'woSign'])),
        ('admin.js: кросс-сегменты (П6/Д4)', all(
            m in adm_js for m in ['is_vip', 'is_repeat', 'is_new', 'cstSegs',
                                  'syncCstSegBtn', 'Сегменты'])),
        ('admin.js: ФИО-ссылка + контакты у ФИО (П4/П5)', all(
            m in adm_js for m in ['clients.html?client=', 'показать контакты'])),
        ('admin.js: возвраты-боксы (П8) + новые таблицы списаний (П10)', all(
            m in adm_js for m in ['allSum', 'Всего заявок', 'drawWoSurplus',
                                  'drawWoManual'])),
        ('admin.js: промо без «использовано» (П25)',
         'использовано: ' not in adm_js and 'без лимита' in adm_js),
        ('admin.html: cst-seg-pop + table-wo-surplus/manual + cst-empty ниже таблицы',
         all(m in adm_html for m in ['cst-seg-pop', 'table-wo-surplus',
                                     'table-wo-manual'])
         and adm_html.index('id="cst-empty"') > adm_html.index('id="cst-body"')),
        ('clients.js: «показать контакты» у ФИО (П5)',
         'показать контакты' in clients_js),
        ('users.js/html: матрица доступа + журнал в «Пользователях» (П22/П23)', all(
            m in users_js for m in ['ACCESS_MATRIX', 'renderAccessMatrix',
                                    'panel-audit'])
         and 'roles-matrix-body' in users_html and 'users.html#audit' in users_html),
        ('manage.html: вкладка/секция журнала убраны (П23)',
         'panel-audit' not in manage_html and 'manage.html#audit' not in manage_html),
        ('looks: заглушка «Фотокомплекта» (П15)',
         'lkShowPreview' in looks_js and 'lk-img-preview' in read('looks.html')),
        ('brandbook: модалка сравнения ~600px, темы вертикально (П21)',
         'min(600px' in bb_html and '.bbc-themes { grid-template-columns: 1fr;' in acss),
        ('styles.css: пилюли бейджей min/max-width + фильтр атрибутов',
         all(m in css for m in ['card-badges', 'min-width: 72px', 'max-width: 180px',
                                'af-pop', 'attr-chip', 'pm-attrs'])),
        ('admin.css: attrs-editor + wo-стили + матрица',
         all(m in acss for m in ['attrs-editor', 'wo-sign-btn', 'mx-plan-mark',
                                 'cst-seg-pop'])),
    ]
    for name, ok in checks:
        if ok:
            print('OK  S16 статика: %s' % name)
        else:
            fails.append('S16 статика: %s' % name)

# ---------------------------------------------------------------- итог
print()
if fails:
    print('ИТОГ: ПРОВАЛ (%d)' % len(fails))
    for f in fails:
        print(' - ' + f)
    sys.exit(1)
print('ИТОГ: все проверки волны v0.22.0 пройдены')
