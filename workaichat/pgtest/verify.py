#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.17.0 — верификация консолидации SQL.
sisku_b: baseline 01,02,03,04,05,09 (ДВАЖДЫ — идемпотентность) + 26 + 27.
sisku_c: старая цепочка 01→25 (/tmp/oldchain) + 26 + 27.
Диффы каталогов и посевов B↔C должны быть пустыми; смоук — на B.
Запуск из /home/user: python3 pgtest/verify.py
"""
import subprocess
import sys

BASE = '/tmp/baseline'
OLD = '/tmp/oldchain'
BASELINE = ['01_schema.sql', '02_rls_and_access.sql', '03_functions.sql',
            '04_seed_references_and_content.sql', '05_seed_catalog.sql',
            '09_admin_bundles.sql']
INC = ['26_field_limits_and_promo_timezone.sql', '27_webp_image_paths.sql']
import os
OLDCHAIN = sorted(f for f in os.listdir(OLD) if f.endswith('.sql'))

# ожидаемые строки самопроверок (psql -At, pipe-разделитель)
EXPECT = {
    '01_schema.sql': ['22|22|1|1|1|5|2'],
    '02_rls_and_access.sql': ['62|22|14|15|11|0'],
    '03_functions.sql': ['12|t|t|t|5'],
    '09_admin_bundles.sql': ['18|6|t|t|t'],
    '04_seed_references_and_content.sql': ['7|8|3|4|1|0|4|70|18|0|20|1'],
    '05_seed_catalog.sql': ['6|6|8|20|8'],
    '26_field_limits_and_promo_timezone.sql': ['3|t|2|t|t'],
    '27_webp_image_paths.sql': ['8|0|0'],
}

fails = []


def run_sql(db, path):
    r = subprocess.run(['psql', '-d', db, '-v', 'ON_ERROR_STOP=1', '-q', '-At',
                        '-f', path], capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def run_q(db, query):
    r = subprocess.run(['psql', '-d', db, '-At', '-c', query],
                       capture_output=True, text=True)
    assert r.returncode == 0, (db, r.stderr[:300])
    return r.stdout


def check(cond, label):
    print(('PASS ' if cond else 'FAIL ') + label)
    if not cond:
        fails.append(label)


subprocess.run(['psql', '-d', 'postgres', '-q', '-c',
                'drop database if exists sisku_b'], capture_output=True)
subprocess.run(['psql', '-d', 'postgres', '-q', '-c',
                'drop database if exists sisku_c'], capture_output=True)
subprocess.run(['psql', '-d', 'postgres', '-q', '-c',
                'create database sisku_b'], check=True, capture_output=True)
subprocess.run(['psql', '-d', 'postgres', '-q', '-c',
                'create database sisku_c'], check=True, capture_output=True)

# --- B: baseline дважды + инкременты ---------------------------------------
for rnd in (1, 2):
    for f in BASELINE:
        rc, out, err = run_sql('sisku_b', BASE + '/' + f)
        if rc != 0:
            check(False, 'B прогон %d: %s (%s)' % (rnd, f, err.strip()[:200]))
            sys.exit(1)
        if rnd == 1:
            for e in EXPECT[f]:
                check(e in out, 'B самопроверка %s: ждём %s' % (f, e))
for f in INC:
    rc, out, err = run_sql('sisku_b', BASE + '/' + f)
    check(rc == 0, 'B инкремент %s' % f)
    for e in EXPECT[f]:
        check(e in out, 'B самопроверка %s: ждём %s' % (f, e))

# --- C: старая цепочка + инкременты ----------------------------------------
for f in OLDCHAIN:
    rc, out, err = run_sql('sisku_c', OLD + '/' + f)
    if rc != 0:
        check(False, 'C старая цепочка: %s (%s)' % (f, err.strip()[:200]))
        sys.exit(1)
for f in INC:
    rc, out, err = run_sql('sisku_c', BASE + '/' + f)
    check(rc == 0, 'C инкремент %s' % f)

# --- Диффы B ↔ C ------------------------------------------------------------
DIFFS = {
    'колонки': """select table_name, column_name, data_type, is_nullable,
       coalesce(column_default,'') from information_schema.columns
       where table_schema='public' order by 1,2""",
    'констрейнты': """select c.conname, c.contype, cl.relname,
       pg_get_constraintdef(c.oid) from pg_constraint c
       join pg_class cl on cl.oid=c.conrelid
       join pg_namespace n on n.oid=cl.relnamespace
       where n.nspname='public' order by 1,3""",
    'политики': """select tablename, policyname, permissive, cmd,
       array_to_string(roles,','), coalesce(qual,''), coalesce(with_check,'')
       from pg_policies where schemaname='public' order by 1,2""",
    'индексы': """select tablename, indexname, indexdef from pg_indexes
       where schemaname='public' order by 1,2""",
    'функции': """select p.proname, pg_get_function_identity_arguments(p.oid),
       pg_get_functiondef(p.oid) from pg_proc p
       join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' order by 1""",
    'RLS-флаги': """select cl.relname, cl.relrowsecurity, cl.relforcerowsecurity
       from pg_class cl join pg_namespace n on n.oid=cl.relnamespace
       where n.nspname='public' and cl.relkind='r' order by 1""",
    'комментарии таблиц': """select cl.relname, coalesce(obj_description(cl.oid),'')
       from pg_class cl join pg_namespace n on n.oid=cl.relnamespace
       where n.nspname='public' and cl.relkind='r' order by 1""",
    'комментарии колонок': """select cl.relname, a.attname,
       coalesce(col_description(cl.oid, a.attnum),'')
       from pg_class cl join pg_namespace n on n.oid=cl.relnamespace
       join pg_attribute a on a.attrelid=cl.oid
       where n.nspname='public' and cl.relkind='r' and a.attnum>0
         and not a.attisdropped order by 1,2""",
    'комментарии функций': """select p.proname, coalesce(obj_description(p.oid),'')
       from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' order by 1""",
    'последовательности': """select sequencename, coalesce(last_value::text,'NULL')
       from pg_sequences where schemaname='public' order by 1""",
}
for label, query in DIFFS.items():
    b, c = run_q('sisku_b', query), run_q('sisku_c', query)
    if b != c:
        bl, cl = b.split('\n'), c.split('\n')
        diff_lines = [x for x in bl if x not in cl][:3] + \
                     [x for x in cl if x not in bl][:3]
        print('  первые отличия (%s): %s' % (label, diff_lines))
    check(b == c, 'дифф B↔C: %s' % label)

SEED_TABLES = ['order_statuses', 'status_transitions', 'payment_methods',
               'delivery_methods', 'return_reasons', 'site_content',
               'brand_colors', 'brands', 'categories', 'products',
               'product_variants', 'admin_users']
for t in SEED_TABLES:
    cols = run_q('sisku_b', """select string_agg(column_name, ', '
                  order by ordinal_position) from information_schema.columns
                  where table_schema='public' and table_name='%s'
                    and column_name not in ('created_at','updated_at')""" % t).strip()
    q = 'select %s from public.%s order by 1' % (cols, t)
    check(run_q('sisku_b', q) == run_q('sisku_c', q), 'дифф данных B↔C: %s' % t)

# --- Смоук на B --------------------------------------------------------------
rc, out, err = run_sql('sisku_b', 'pgtest/smoke17.sql')
check(rc == 0, 'смоук-тест (rc=%s) %s' % (rc, err.strip()[:300]))
for line in out.strip().split('\n'):
    if line.startswith('PASS') or line.startswith('FAIL'):
        check(line.startswith('PASS'), 'смоук: ' + line)

# --- RLS под anon (гранты платформы Supabase — harness-only) ------------------
subprocess.run(['psql', '-d', 'sisku_b', '-q', '-c',
                'grant usage on schema public to anon; '
                'grant all on all tables in schema public to anon; '
                'grant all on all sequences in schema public to anon; '
                'grant execute on all functions in schema public to anon;'],
               check=True, capture_output=True)
ANON_OK = [
    # (sql, ожидание: 't' в stdout / 'error' — ненулевой rc)
    ("select count(*) > 0 from public.products", 't'),
    ("select count(*) >= 0 from public.return_reasons", 't'),
    ("select public.track_order(1, '0001') is not null", 't'),
    ("insert into public.return_requests (order_id, reason_id, status, created_by)"
     " values (1, 1, 'created', 'x')", 'error'),
    # RLS без политики → 0 затронутых строк (не ошибка) — проверяем счётчиком
    ("with d as (delete from public.return_reasons where id = 1 returning 1)"
     " select count(*) = 0 from d", 't'),
    ("with u as (update public.orders set comment = 'взлом' where id = 1 returning 1)"
     " select count(*) = 0 from u", 't'),
    ("with d as (delete from public.return_requests where id = 1 returning 1)"
     " select count(*) = 0 from d", 't'),
    # позитивный контроль: draft-CRUD каталога разрешён анонимно (граница черновика)
    ("with u as (update public.products set name = name where id = 1 returning 1)"
     " select count(*) = 1 from u", 't'),
]
for sql, expect in ANON_OK:
    r = subprocess.run(['psql', '-d', 'sisku_b', '-At', '-c',
                        'begin; set local role anon; ' + sql + '; rollback;'],
                       capture_output=True, text=True)
    if expect == 'error':
        ok = r.returncode != 0
        label = 'запрещено (ошибка)'
    else:
        ok = r.returncode == 0 and expect in r.stdout.split()
        label = 'ожидание «%s»' % expect
    check(ok, 'RLS anon %s: %s' % (label, sql[:70]))

print()
if fails:
    print('ИТОГ: %d ПРОВАЛОВ: %s' % (len(fails), fails))
    sys.exit(1)
print('ИТОГ: ВСЕ ПРОВЕРКИ ЗЕЛЁНЫЕ (baseline == старая цепочка; инкременты работают; RLS держит)')
